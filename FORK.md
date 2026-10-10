# Connor's fork of Search

Office Commun's [Search](https://github.com/driceroland/Search), with a few changes on the `connor` branch.

## What's different

- **Named Connor's Search** in the Dock, menu bar and Spotlight. The data folders and bundle id are still Search's, so nothing moved.
- **AI is on.** View › Ask About This Page… (⌘E). Pick a provider in Settings › AI. Keys go in the login keychain, because this build isn't signed with Office Commun's provisioning profile.
- **The AI does things on the page.** Tell it what you want: "search for trail shoes", "pick large and add it to my cart", "take me to pricing", "open my orders". It reads the page's buttons, links and fields, takes one step at a time, outlines what it's pressing, and lists each step under its answer. Stop ends it at any point, and it stops by itself after 15 steps. If you name a heading or link that's on the page, Search goes there itself and nothing is sent to the model.
- **It asks first** before anything that leaves for another site you didn't name, anything whose label or link says buy, pay, send, post, delete, sign out and the like, any form that posts or isn't a search of the same site ("Add to cart" excepted), and any "OK" or "Yes" in a pop-up dialog. On a page with text written to steer an AI, it asks before every step. It never sees or types into password or card fields, and never sees what's typed in a box.
- **Bookmarks under the pins,** like Arc or Dia. Each space shows the top-level bookmarks folder with the same name as the space. To pick a different folder, right-click the space icon › Bookmarks in Sidebar.
- **No Office Commun updates.** Their builds are signed by another team and would be refused anyway. Update from upstream instead (below).

## Updating from upstream

```bash
git fetch upstream
git merge upstream/main      # fix any conflicts, then:
./build.sh
python3 Tests/fork_shelf_ai.py
python3 Tests/fork_agent.py
```

Then quit it, move `/Applications/Connor's Search.app` to the Trash, and copy `build/Search.app` to `/Applications/Connor's Search.app`.

The fork's changes are kept small and mostly in their own files (`Sources/Search/Shelf.swift`, `Sources/Search/AIAct.swift`), so merges should rarely conflict.
