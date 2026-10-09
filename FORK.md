# Connor's fork of Search

Office Commun's [Search](https://github.com/driceroland/Search), with a few changes on the `connor` branch.

## What's different

- **AI is on.** View › Ask About This Page… (⌘E). Pick a provider in Settings › AI. Keys go in the login keychain, because this build isn't signed with Office Commun's provisioning profile.
- **"Take me to…"** Ask the AI panel "take me to pricing" or "open the careers page". If you name a heading or link that's on the page, Search goes there itself and nothing is sent to the model. For vaguer requests ("where do I see what it costs?"), the model picks from the page's numbered headings and links. Sections are scrolled to, and pages on the same site open in the tab. Pages on another site only appear as a button you have to click.
- **Bookmarks under the pins,** like Arc or Dia. Each space shows the top-level bookmarks folder with the same name as the space. To pick a different folder, right-click the space icon › Bookmarks in Sidebar.
- **No Office Commun updates.** Their builds are signed by another team and would be refused anyway. Update from upstream instead (below).

## Updating from upstream

```bash
git fetch upstream
git merge upstream/main      # fix any conflicts, then:
./build.sh
python3 Tests/fork_shelf_ai.py
```

Then quit Search, move `/Applications/Search.app` to the Trash, and copy `build/Search.app` into `/Applications`.

The fork's changes are kept small and mostly in their own file (`Sources/Search/Shelf.swift`), so merges should rarely conflict.
