# Emulator smoke checklist

Manual checks after any change that touches plugin loading, the menu, settings
or the folder picker. Twenty minutes, and it catches the class of failure the
automated suites structurally cannot: anything that only happens when KOReader
actually starts and someone taps something.

Several bugs have been found here that the specs could not see.

## Setup

```bash
scripts/link-plugin.sh /path/to/koreader
cd /path/to/koreader/koreader-emulator-*/koreader
./luajit reader.lua 2>&1 | tee /tmp/karabridge-koreader.log
```

With a working X11 display no extra setup is needed. Without one:

```bash
xvfb-run -a -s "-screen 0 600x800x24" ./luajit reader.lua 2>&1 | tee /tmp/karabridge-koreader.log
```

For a device-shaped screen, from the KOReader root:
`./kodev run -s=kobo-clara`.

Inspect afterwards:

```bash
grep -i karabridge /tmp/karabridge-koreader.log
```

Two SDL messages are container noise and can be ignored:
`XDG_RUNTIME_DIR is invalid or not set`, and `XIO: fatal IO error` at teardown.

---

## A. Loading

- [ ] **A1** The log has
      `KaraBridge: loaded version <v>, main.lua modified <when>, from <path>`.
- [ ] **A2** The path in A1 is the working copy, not a stale manual install.
      This is the whole reason the line prints a path and a modification time —
      a version string cannot tell the two apart.
- [ ] **A3** No `Error when loading plugins/karabridge.koplugin/main.lua`.
- [ ] **A4** No `module '…' not found` for anything under `karabridge.`.
      *(A module written as `x/init.lua` fails here and passes in the unit
      suite. PluginLoader sets `package.path` to `plugin_root/?.lua` only.)*
- [ ] **A5** No Lua stack trace anywhere in the log.
- [ ] **A6** KaraBridge appears in **Tools → Plugin management**, enabled.

## B. Menu

- [ ] **B1** **Tools → More tools → KaraBridge** exists.
- [ ] **B2** Every row has a visible label — no blank rows.
- [ ] **B3** With nothing configured: `Server: not set`,
      `Download folder: not set`, `Settings file: none`.
- [ ] **B4** Every submenu opens: Download folder, Settings file, Diagnostics.
- [ ] **B5** Long-pressing the Settings file row shows its help text.

## C. Server settings and the connection test

- [ ] **C1** Tapping the Server row opens the two-field dialog.
- [ ] **C2** The API key field renders as dots, not text.
- [ ] **C3** Enter a bad address (`not-a-url`) and save → a message saying the
      address must start with `https://` or `http://`. The value is refused,
      not stored.
- [ ] **C4** Enter `https://karakeep.example.org/api/v1/` → after saving, the
      menu shows `https://karakeep.example.org`. The trailing slash and
      `/api/v1` are stripped.
- [ ] **C5** The menu row shows the key masked: `(key ******abcd)`, never the
      key.
- [ ] **C6** **Test the connection** against a real server → *Connected to
      Karakeep as …*.
- [ ] **C7** Against a plain `http://` server → the success message also warns
      the key is sent unencrypted.
- [ ] **C8** With a wrong key → *Karakeep rejected the API key*, mentioning
      Settings → API Keys.
- [ ] **C9** Against a non-Karakeep address (the web UI root, say) → *No
      Karakeep API answered at that address*, mentioning `/api/v1`.
- [ ] **C10** Against an unroutable address → *The server could not be
      reached*, within about a minute rather than hanging.
- [ ] **C11** Cancel the dialog → nothing is changed.

## D. Folder picker

- [ ] **D1** **Download folder → Choose a folder…** opens the native
      `PathChooser`.
- [ ] **D2** Confirm a folder → a toast shows the path, and the menu row
      updates immediately.
- [ ] **D3** The row shows the **full** path, not a shortened one.
- [ ] **D4** **Dismiss the picker without confirming** → nothing changes, no
      message, no error. *(`chooseDir` calls `onConfirm` only on
      confirmation; there is deliberately no cancel path.)*
- [ ] **D5** Reopening the picker starts at the currently selected folder.
- [ ] **D6** **Type a path…** with a folder that does not exist → it is
      created, and accepted.
- [ ] **D7** Type a path under a read-only parent → the setting is **still
      saved**, and a message explains it cannot be written to, naming Flatpak
      permissions as a possibility.
- [ ] **D8** **Check the current folder** on a good folder → confirms it is
      writable.
- [ ] **D9** No `.karabridge-write-test` file is left behind:
      `ls -a <folder>`.

## E. Configuration file

- [ ] **E1** With no file present: `Settings file: none`.
- [ ] **E2** **Where KaraBridge looks** lists four candidates in order, none
      ticked.
- [ ] **E3** **Create an example file** → written to the data directory, with a
      message giving the path.
- [ ] **E4** Running it again → *already exists … left untouched*. Nothing is
      overwritten.
- [ ] **E5** The generated file parses: every line either a comment or a valid
      setting. Only `server_url` and `api_token` are uncommented.
- [ ] **E6** Edit it — set `articles_per_sync = 11` and add a deliberate typo
      such as `bogus_key = 1` — then restart. The log shows
      `seeded N setting(s) from …` and a warning naming `bogus_key` **with its
      line number**.
- [ ] **E7** `Settings file: found, with problems`, and **Where KaraBridge
      looks** ticks the file and lists the problem.
- [ ] **E8** Restart again → `seeded 0 setting(s) … N already set on the device
      and left alone`. **This is the precedence rule.** The file seeds once.
- [ ] **E9** Change `articles_per_sync` in the menu, restart → the menu value
      survives. The file does **not** win.
- [ ] **E10** Edit the file, then **Reload it now** → *Applied N setting(s)*,
      and the file's value now wins. This is the only override.
- [ ] **E11** Put a file in the plugin directory only → it is found (candidate
      4).
- [ ] **E12** Put files in the data directory **and** the plugin directory →
      the data directory one is used, and is the ticked one.

## F. Diagnostics

- [ ] **F1** **Version and paths** shows the version, the load path, and the
      settings file path.
- [ ] **F2** **Current settings** lists every setting with its origin —
      `[file]`, `[device]` or `[default]`.
- [ ] **F3** `api_token` is masked. **This screen must be safe to
      photograph.**
- [ ] **F4** A server address entered with credentials (if one ever got in) is
      shown as `https://(userinfo)@host`.

## G. Persistence

- [ ] **G1** Configure everything, quit cleanly, restart → all settings
      survive.
- [ ] **G2** `settings/karabridge.lua` contains what was set, and no key that
      was never set.
- [ ] **G3** Kill the emulator (`kill -9`) rather than quitting, restart →
      settings saved before the last flush survive. *(KOReader flushes on
      `onFlushSettings`; a hard kill can lose the very last change, which is
      expected.)*

## H. Security

Run these **every time**, they are cheap:

- [ ] **H1** `grep -c "$(your api token)" /tmp/karabridge-koreader.log` → `0`.
- [ ] **H2** `grep -i "bearer" /tmp/karabridge-koreader.log` → nothing from
      KaraBridge.
- [ ] **H3** `grep -i "authorization" /tmp/karabridge-koreader.log` → nothing
      from KaraBridge.
- [ ] **H4** No API token in `settings/karabridge.lua` *comments* or anywhere
      other than the `api_token` value itself.

*(Logging a request table wholesale, headers included, writes the API key to
the log at debug level. That is the bug these three checks exist to catch.)*

## I. Coexistence

Only when another Karakeep integration is installed alongside:

- [ ] **I1** Both plugins load and both menus appear.
- [ ] **I2** Their settings files are separate and neither is modified by the
      other plugin.
- [ ] **I3** Downloads carrying another plugin's filename prefix are ignored by
      KaraBridge — in particular **not deleted** by any KaraBridge sync.
- [ ] **I4** A book whose sidecar already holds a legacy bookmark ID is
      **updated**, not duplicated, by KaraBridge's first export.
- [ ] **I5** The legacy `karakeep` sidecar key still holds its original value
      afterwards.

## J. Article download

- [ ] **J1** **Download articles only** with a usable folder → progress shows
      one article at a time, then a summary.
- [ ] **J2** The downloaded files are named `[kb-id_…] Title.epub`.
- [ ] **J3** Each one opens and renders.
- [ ] **J4** Running it again → *0 downloaded, N already on the device*.
      Nothing is fetched twice.
- [ ] **J5** Cancel mid-download → the summary says cancelled, and the
      articles already written are intact.
- [ ] **J6** With **Embed images** off, an image-heavy article still builds and
      shows no broken-image boxes.
- [ ] **J7** Set a `filter_list` that does not exist → a message naming the
      list, not a generic failure.

## K. Sending back

- [ ] **K1** Open a downloaded article, highlight a passage, close it.
- [ ] **K2** **Send read status and highlights** → *Sent 1 highlight*.
- [ ] **K3** The highlight appears in Karakeep with its text and, if the
      article has chapters, the chapter in the note.
- [ ] **K4** Run it again → *0 highlights*. **No duplicate in Karakeep.**
- [ ] **K5** Mark an article as finished, sync → it is archived in Karakeep,
      and the local copy is deleted if that setting is on.
- [ ] **K6** With the server unreachable, sync → the failure is reported and
      the local file is **left alone**, so the next run retries.

## L. Book export

- [ ] **L1** Open one of your own EPUBs, highlight something.
- [ ] **L2** **KaraBridge → Export book highlights** says *off (not ticked as
      an export target)* before anything is done. It must say **why**, not just
      "off".
- [ ] **L3** Tapping it turns it on, and the message names where the export
      action lives.
- [ ] **L4** **Tools → Export highlights → Formats** now shows **Karabridge**
      ticked. *(One tap sets both switches; if it does not, the two can
      disagree and an export silently does nothing.)*
- [ ] **L5** With the server unconfigured, tapping the row refuses with an
      explanation rather than appearing to work.
- [ ] **L6** Tools → Export highlights lists **Karabridge** as a target at all.
      *(If not, the provider registration regressed — see ADR-002.)*
- [ ] **L7** **Export all notes in current book** → one Karakeep text card,
      titled `Book — Author`.
- [ ] **L8** The card groups highlights by chapter, with page numbers.
- [ ] **L9** Export again with no new highlights → *N unchanged*, and
      `modifiedAt` in Karakeep does not move.
- [ ] **L10** Add a highlight and export → the **same** card is updated, not a
      second one created.
- [ ] **L11** Delete the card in Karakeep's web UI, export again → a new card is
      created and the book is exportable again.
- [ ] **L12** With `book_tag` and `book_list` set, a new card carries both.
- [ ] **L13** Karakeep's **Highlights** view lists the book's passages, one
      entry per highlight -- the same as for an article.
- [ ] **L14** Each highlight carries its chapter in the note, and its colour
      matches the one used in KOReader.
- [ ] **L15** Export again with nothing changed -> **no second copy** of any
      highlight appears.
- [ ] **L16** Edit a highlight's note in Karakeep, export again -> the note
      arrives on the matching KOReader annotation, and no annotation is
      duplicated. *(Nothing is written to the card itself; the highlights still
      sync.)*
- [ ] **L17** Highlight the *same sentence* in two chapters and export -> two
      separate highlights in Karakeep, not one.
- [ ] **L18** Delete the card in Karakeep **without changing anything in the
      book**, then export -> a new card is created.
- [ ] **L19** That new card carries **all** the highlights again, not none.
      *(The old highlight IDs died with the old card; the mapping has to know
      it no longer applies.)*
- [ ] **L20** **Without closing the book**, mark one more passage and export
      again -> it appears both in the card **and** in Karakeep's Highlights
      view. *(KOReader keeps this session's annotations in memory, so a sync
      that read the `.sdr` file would not see them.)*
- [ ] **L21** Edit a note in Karakeep, export, then **close the book** and
      reopen it -> the note is still there. *(KOReader writes its in-memory
      array over the whole sidecar on close, so a note written to the file
      instead of the array is lost.)*
- [ ] **L22** After closing and reopening, export once more -> the **same**
      card is updated. A second card means the stored bookmark ID did not
      survive the close.
- [ ] **L24** The card carries the book's cover. Karakeep's **list** layout
      shows it, and the preview page lists it under attachments. *(It will
      **not** appear as a grid thumbnail -- a text bookmark's `bannerImageUrl`
      is null by design. Not a bug.)*
- [ ] **L25** Export again -> no second upload and no second asset on the card.
- [ ] **L26** A book without a cover, or a PDF, exports normally and just has
      none. Nothing in the summary suggests a failure.
- [ ] **L27** With `upload_book_cover = false` in `karabridge.conf`, no asset is
      uploaded at all.

- [ ] **L23** Export while an article KaraBridge **downloaded** is open, or use
      "all books" -> no text card is created for it, and the summary says it
      was an article. *(It is already a bookmark; a card would duplicate it and
      steal its highlight mapping.)*

## M. Queue

- [ ] **M1** With Wi-Fi off, tap an external link in a book → **Save to
      Karakeep** appears in the dialog.
- [ ] **M2** Tapping it says the link will be saved at the next sync.
- [ ] **M3** The KaraBridge menu now shows **Send 1 queued item**.
- [ ] **M4** Restart → the queued item is still there.
- [ ] **M5** With Wi-Fi on, **Send 1 queued item** → the bookmark appears in
      Karakeep and the row goes back to being greyed out.
- [ ] **M6** With a deliberately wrong API key, send repeatedly → after five
      attempts it moves to **Diagnostics → Set-aside items** with a reason.

## N. Automatic syncing

- [ ] **N1** **Automatic syncing → Sync when Wi-Fi connects** on, then connect
      Wi-Fi → a sync runs and reports through a **toast**, not a modal.
- [ ] **N2** Connect again straight away → nothing happens; the interval
      throttles it.
- [ ] **N3** With a book open, connect Wi-Fi → only status and highlights are
      sent. **No download dialog interrupts reading.**
- [ ] **N4** With the setting off, connecting Wi-Fi does nothing at all.
- [ ] **N5** KaraBridge's three actions appear under
      **Gesture manager → Add action**.

## Not covered here

Real-device behaviour: storage paths on internal and SD, memory on a large
highlight set, touch interaction, and how long an image-heavy article takes to
build on a Kobo's CPU. Those need a Kobo.

---

## Log for a run

```
Date:
KOReader:        (commit or version)
KaraBridge:      (version, and the modification time from A1)
Platform:        (emulator profile, or the device)
Checks run:      A– …
Failures:
Notes:
```
