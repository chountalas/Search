#!/usr/bin/env python3
"""Connor's fork: bookmarks under the pins (Shelf) and the AI taking you
somewhere ("take me to pricing"), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fork_shelf_ai.py`. It uses
the split suite's harness: started hidden in a world of its own, driven
through ./bench's socket, everything removed afterwards. The AI answers come
from a stand-in on this Mac that reads the prompt the way a model would —
the numbered places Search sends — and picks one by the question's words,
so the run is the same every time and nothing leaves the Mac.
"""
import json
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fork-shelf-ai")

FILLER = "<p>" + "Lorem ipsum dolor sit amet. " * 400 + "</p>"


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        if self.path == "/":
            body = (f"<!doctype html><title>Acme Outdoor</title><h1>Acme Outdoor</h1>"
                    f"<a href='/careers'>Careers</a> <a href='http://localhost:{port}/partner'>Partner site</a>"
                    f"{FILLER}<h2 id='pricing'>Pricing</h2>{FILLER}<h2 id='contact'>Contact</h2>{FILLER}")
        elif self.path == "/careers":
            body = f"<!doctype html><title>Careers</title><h1>Careers</h1>{FILLER}<h2 id='roles'>Open roles</h2>{FILLER}"
        else:
            body = f"<!doctype html><title>{self.path}</title><h1>{self.path}</h1>"
        data = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def log_message(self, *a): pass


asked = []  # every request the stand-in got, for the checks on the prompt


class Model(BaseHTTPRequestHandler):
    """Chat completions, streamed, as Ollama answers them. Asked where
    something is, it reads the question for what it means — costs is
    pricing, jobs are roles — and picks from the numbered places."""
    MEANS = {"costs": "pricing", "cost": "pricing", "price": "pricing", "jobs": "roles", "hiring": "roles",
             "work": "careers"}

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        asked.append(body)
        users = [m["content"] for m in body["messages"] if m["role"] == "user"]
        question = users[-1].split("My request is:\n")[-1].strip().lower()
        listing = next((u for u in reversed(users) if "Places on this page:" in u), "")
        places = re.findall(r"^(\d+)\. (?:link|section of this page): (.+?)(?: → \S+)?$", listing, re.M)
        words = [self.MEANS[w] for w in re.findall(r"[a-z]+", question) if w in self.MEANS]
        going = question.startswith("where")
        pick = next((n for n, text in places if any(w in text.lower() for w in words)), None) if going else None
        reply = (f"Taking you to that part now.\nGO {pick}" if pick
                 else "This is the Acme Outdoor page.")
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for i in range(0, len(reply), 6):
            chunk = {"choices": [{"delta": {"content": reply[i:i + 6]}}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode()); self.wfile.flush(); time.sleep(0.02)
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a): pass


site = ThreadingHTTPServer(("127.0.0.1", 0), Site); threading.Thread(target=site.serve_forever, daemon=True).start()
model = ThreadingHTTPServer(("127.0.0.1", 0), Model); threading.Thread(target=model.serve_forever, daemon=True).start()
SITE = f"http://127.0.0.1:{site.server_port}"


def ai(action, **f): return sv.cmd({"do": "ai", "action": action, **f})


def ask(tab, text, within=15):
    """A question in the panel, and its turn once it's done."""
    before = len(ai("state").get("turns", []))
    ai("question", id=tab, text=text)
    until = time.time() + within
    while time.time() < until:
        turns = ai("state").get("turns", [])
        if len(turns) > before and turns[-1]["done"] and (not turns[-1]["acting"] or turns[-1]["waiting"]):
            time.sleep(1.5)  # the scroll is smooth; the outline and the load follow
            return ai("state")["turns"][-1]
        time.sleep(0.2)
    return {}


def top(tab, id):
    found = sv.ev(tab, f"Math.round(document.getElementById('{id}').getBoundingClientRect().top)")
    return 9999 if found is None else found


def url(tab): return sv.ev(tab, "location.href")


t = sv.T()
try:
    sv.setup(spaces=True)
    # Two spaces as Connor has them: the first one, and LOA with sign-ins of
    # its own; a bookmarks folder named for each.
    loa = str(uuid.uuid4()).upper()
    Path(sv.SUPPORT).mkdir(parents=True, exist_ok=True)
    json.dump([{"id": sv.FIRST_SPACE, "name": "Work", "colour": 0},
               {"id": loa, "name": "LOA", "colour": 0, "icon": "building.2"}], open(f"{sv.SUPPORT}/spaces.json", "w"))
    def mark(title, path): return {"id": str(uuid.uuid4()).upper(), "title": title, "url": f"{SITE}{path}"}
    def folder(title, kids): return {"id": str(uuid.uuid4()).upper(), "title": title, "children": kids}
    json.dump([folder("Work", [folder("Mortals", [mark("Mortals home", "/mortals")]), mark("Careers page", "/careers")]),
               folder("LOA", [folder("Zoning", [mark("Calgary bylaw", "/bylaw")]), mark("Ledger", "/ledger")])],
              open(f"{sv.SUPPORT}/bookmarks.json", "w"))
    sv.launch()

    # -- the shelf
    st = sv.cmd({"do": "shelf"})
    t.ok("shelf: the first space shows its folder", st["folder"] == "Work", st)
    t.ok("shelf: its rows, folders closed", [l["title"] for l in st["lines"]] == ["Mortals", "Careers page"], st["lines"])
    st = sv.cmd({"do": "shelf", "title": "Mortals"})
    t.ok("shelf: a folder opens in place", [(l["title"], l["depth"]) for l in st["lines"]]
         == [("Mortals", 0), ("Mortals home", 1), ("Careers page", 0)], st["lines"])
    tabs = st["tabs"]
    st = sv.cmd({"do": "shelf", "title": "Careers page"}); time.sleep(1.5); st = sv.cmd({"do": "shelf"})
    t.ok("shelf: a bookmark opens a tab", st["tabs"] == tabs + 1 and st["active"] == f"{SITE}/careers", st)
    sv.sp("select", id=sv.page("other")); time.sleep(0.5)
    st = sv.cmd({"do": "shelf", "title": "Careers page"}); time.sleep(1); st = sv.cmd({"do": "shelf"})
    t.ok("shelf: pressed again, it goes back to that tab, not a copy", st["tabs"] == tabs + 2 and st["active"] == f"{SITE}/careers", st)
    sv.sp("space", spaceAction="go", spaceID=loa); time.sleep(1.2)
    st = sv.cmd({"do": "shelf"})
    t.ok("shelf: LOA shows LOA's folder", st["space"] == "LOA" and [l["title"] for l in st["lines"]] == ["Zoning", "Ledger"], st)
    t.ok("shelf: LOA doesn't show Work's bookmarks",
         "Mortals home" not in [l["title"] for l in st["lines"]], st["lines"])
    sv.sp("space", spaceAction="go", spaceID=sv.FIRST_SPACE); time.sleep(1.2)
    sv.cmd({"do": "shelf", "title": "Mortals"})  # closed again

    # -- the AI taking you somewhere
    ai("mock", url=f"http://127.0.0.1:{model.server_port}/")
    ai("use", provider="ollama", model="stand-in")
    home = sv.page(""); sv.cmd({"do": "go", "id": home, "url": f"{SITE}/"}); time.sleep(1.5)
    read = ai("read", id=home)
    kinds = [(p[0], p[1]) for p in read["places"]]
    t.ok("read: the headings are places", ("section", "Pricing") in kinds and ("section", "Contact") in kinds, kinds)
    t.ok("read: the links are places", ("link", "Careers") in kinds and ("link", "Partner site") in kinds, kinds)
    t.ok("before: at the top", top(home, "pricing") > 1000, top(home, "pricing"))

    sent = len(asked)
    turn = ask(home, "take me to pricing")
    t.ok("named outright: nothing sent to the model", len(asked) == sent, len(asked) - sent)
    t.ok("pricing: scrolled to the section", -5 <= top(home, "pricing") <= 60, top(home, "pricing"))
    t.ok("pricing: said under the answer", turn.get("went") == "Scrolled to “Pricing”", turn)

    sv.ev(home, "window.scrollTo(0, 0)"); time.sleep(0.5)
    turn = ask(home, "where do I see how much it costs?")
    prompt = asked[-1]["messages"]
    t.ok("in other words: the model is asked", len(asked) == sent + 1, len(asked) - sent)
    t.ok("prompt: the places go inside the page's fence",
         re.search(r"<page-\w+>[\s\S]*Places on this page:[\s\S]*Pricing[\s\S]*</page-\w+>", prompt[-1]["content"]) is not None)
    t.ok("prompt: the system says how to answer with GO", "GO 7" in prompt[0]["content"])
    t.ok("prompt: the reminder sits under the request, outside the fence",
         prompt[-1]["content"].rstrip().endswith("write no action line.)"))
    t.ok("costs: the model's pick is scrolled to", -5 <= top(home, "pricing") <= 60, top(home, "pricing"))
    t.ok("costs: the GO line isn't shown", "GO" not in turn.get("shown", "GO") and turn["shown"].startswith("Taking you"), turn)

    turn = ask(home, "what is this page about")
    t.ok("plain question: answered, nowhere to go", turn.get("went") == "" and turn.get("waiting") == "" and turn.get("steps") == [], turn)

    sent = len(asked)
    turn = ask(home, "where could I work here?")
    t.ok("model's link pick: the model is asked", len(asked) == sent + 1, len(asked) - sent)
    t.ok("model's link pick: same site, nothing weighty, so opened", url(home) == f"{SITE}/careers" and turn.get("went") == "Opened “Careers”", (url(home), turn))
    sv.cmd({"do": "go", "id": home, "url": f"{SITE}/"}); time.sleep(1.5)

    turn = ask(home, "open the careers page")
    t.ok("careers: the same site's page opens in this tab", url(home) == f"{SITE}/careers", url(home))
    t.ok("careers: said under the answer", turn.get("went") == "Opened “Careers”", turn)

    turn = ask(home, "where are the jobs listed?")
    first = next(m["content"] for m in asked[-1]["messages"] if m["role"] == "user")
    t.ok("follow-up on the new page: it is read again", "Open roles" in first and "Pricing" not in first, first[-400:])
    t.ok("roles: scrolled on the new page", -5 <= top(home, "roles") <= 60, top(home, "roles"))

    sv.cmd({"do": "go", "id": home, "url": f"{SITE}/"}); time.sleep(1.5)
    turn = ask(home, "go to the partner site")
    t.ok("partner: another site waits for a go-ahead", url(home) == f"{SITE}/" and turn.get("waitingURL", "").endswith("/partner"), (url(home), turn))
    ai("allow")
    until = time.time() + 10  # a busy machine can be slow to start the load
    while time.time() < until and not url(home).endswith("/partner"): time.sleep(0.1)
    t.ok("partner: allowed, it opens", url(home).endswith("/partner"), url(home))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
