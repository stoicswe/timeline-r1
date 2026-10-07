# timeline-r1

## Install on your r1 — scan this

<p align="center">
  <img src="docs/install-qr.png" alt="Scan with your r1 to install Timeline" width="260" />
</p>

**On your r1:** open the creations card → **add via QR code** → scan the code
above. Timeline installs as a tile. (Because the app is hosted on GitHub Pages,
not by Rabbit, the r1 asks you to confirm an untrusted source — that is expected.)

The code encodes Rabbit's creation descriptor for the app hosted at
<https://stoicswe.github.io/timeline-r1/index.html>. If you would rather use a
link than the image, Rabbit's own share page shows the same code:

```
https://www.rabbit.tech/share_creation?title=Timeline&description=A%20day-by-day%20timeline%20of%20what%20you%27ve%20discussed%20with%20the%20r1%20and%20OS3.&url=https%3A%2F%2Fstoicswe.github.io%2Ftimeline-r1%2Findex.html&themeColor=%23FE5000
```

Installing the app is only half of it — it then needs your own OS3 endpoint
(below). Installing the app alone grants it no access to your OS3 data.

---

A day-by-day timeline for the Rabbit r1: one card per **completed** day of what
you have discussed with the r1 / OS3. Wheel to move through time, side button to
open a card. Built as a self-contained r1 creation plus a small OS3-side endpoint.

The creation itself is data-free and shareable. Each owner runs their own
endpoint on their own machine, so their timeline data never leaves it.

## How it works

```
r1 creation  --HTTPS-->  Cloudflare tunnel  -->  timeline-server.py (127.0.0.1:8791)
                                                        ^
                                                        |
                                          data/timeline.json  <-- OS3 generator task
```

An r1 creation is a static web app the r1 opens full-screen in its WebView. It
has no OS3 login and no documented channel to an OS3 account, and a plain LAN
address is blocked as mixed content / cleartext. So the transport is an ordinary
public HTTPS hostname (a Cloudflare tunnel) that forwards to a small read-only
endpoint on the owner's machine. Only the *transport* is public — the timeline
data stays on the device and on the owner's machine.

The day-cards are produced by an OS3-side scheduled task, because OS3's journal,
meeting recordings and memory live in the cloud and are reachable only through
OS3's own tools. The local endpoint only *serves* the file that task writes.

## What's in here

| path | role |
|---|---|
| `docs/install-qr.png` | the QR above — Rabbit's creation descriptor for the hosted app |
| `install.sh` | **one-command installer** for Linux / macOS — stands up the endpoint + tunnel, verifies, prints the pairing details and the single OS3 paste |
| `install.ps1` | **one-command installer** for Windows (PowerShell) — same, using a per-user Scheduled Task |
| `creation/` | the creation source — `index.html`, `style.css`, `app.js`, `icon.svg` (published to GitHub Pages) |
| `server/timeline-server.py` | the read-only endpoint (CORS, `?since=`, optional token check) |
| `server/supervise.sh` | keeps the endpoint and tunnel up; republishes the pointer when the tunnel URL changes |
| `server/supervise.ps1` | the same supervisor for Windows |
| `server/os3-setup-prompt.md` | the single self-contained OS3 paste (the one manual step) |
| `server/generate-timeline.md` | the generator spec the paste carries |
| `.github/workflows/pages.yml` | publishes `creation/` to GitHub Pages |

`creation/app.js` here is the **distribution build**: the two personal constants
(a pointer gist and a fallback endpoint) are blank, so it ships with no owner's
configuration baked in. A new owner pairs it on the device (below).

## Behaviour

- **Once-a-day refresh.** The creation stores `lastRefreshDay` (UTC date) beside
  its cards and calls the network only if that is not today — at most one fetch
  per day. The endpoint answers `?since=<newest stored date>` so only new cards
  cross the wire. A second open the same day makes zero network calls.
- **Completed days only.** Only days strictly before today are ever stored, so the
  current day in progress never appears.
- **Timeline-refresh requests are excluded.** The creation's own fetches are plain
  HTTPS requests from the WebView and never enter the journal or OS3 memory. The
  generator additionally excludes anything about refreshing/syncing/viewing the
  timeline itself, and emits no card for a day whose only activity was excluded.

## Set up your own endpoint and pair your r1

You need a computer that can reach your own OS3 context and stay online.

### One command, then one paste

Clone the repo and run the installer for your platform. It is readable and
non-destructive: it prints its plan and asks before changing anything, and it
will not touch an existing install without `--force` / `-Force`.

**Linux / macOS:**

```sh
git clone https://github.com/stoicswe/timeline-r1.git
cd timeline-r1
./install.sh
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/stoicswe/timeline-r1.git
cd timeline-r1
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer:

1. checks for Python 3.8+ and `cloudflared`, and offers to download
   `cloudflared` into a private folder — **no sudo / admin needed**;
2. copies the endpoint, supervisor and generator spec into `~/.timeline-r1`;
3. starts the read-only endpoint with a fresh random pairing token;
4. starts a Cloudflare quick tunnel to it;
5. waits out the tunnel-routability delay (~60 s) and **verifies the endpoint is
   actually reachable through the tunnel** before declaring success;
6. installs the supervisor (cron on Linux/macOS, a per-user Scheduled Task on
   Windows) so the endpoint and tunnel restart if either drops;
7. prints the **endpoint URL** and **pairing token** to paste into the creation,
   a `curl`/`Invoke-WebRequest` line to verify, and the **single OS3 paste** (next).

Useful flags: `--dir`, `--port`, `--token`, `--no-supervisor`, `--no-tunnel`,
`--pointer`, `--force`, `--yes`, `--dry-run` (`install.ps1` takes the same as
`-Dir`, `-Port`, …). Run `./install.sh --help` for the list.

### The one manual step: one paste into OS3

Everything on your machine is done by the installer. The **only** step left is
one paste into OS3, and it is irreducible: OS3's journal, recordings and memory
live in OS3's cloud and are readable only through OS3's own tools, and a
scheduled task belongs to your OS3 account — a plain shell script on your
machine cannot create one. So the installer prints a **single self-contained
prompt** (also saved to `~/.timeline-r1/server/os3-setup-prompt.ready.md`):

1. copy the block between `----- BEGIN OS3 PASTE -----` and `----- END OS3 PASTE -----`;
2. paste it into OS3 once;
3. OS3 creates the daily generator schedule (08:00 UTC) for you and replies with
   its id and next fire time.

That prompt already carries the full generator spec, the exact output path on
your machine, and the schedule, so OS3 needs nothing else from you. After the
task runs once, the timeline fills in. Until then it is empty
(`/health` shows `cardCount: 0`).

> There is no programmatic way for a local script to register a schedule in your
> OS3 account, so this paste is the honest minimum. One command on your machine,
> plus this one paste, and nothing else.

### Manual setup (what the installer automates)

If you would rather do it by hand:

1. **Generate the cards.** Create an OS3 scheduled task from
   `server/generate-timeline.md` (or paste `server/os3-setup-prompt.md`). It
   reads your journal, recordings and memory, groups by completed day, and writes
   `data/timeline.json`. Run it daily.
2. **Run the endpoint.** On that machine:
   ```sh
   TIMELINE_PORT=8791 python3 server/timeline-server.py
   ```
   It binds to loopback and serves `data/timeline.json`. To require a pairing
   token, set `TIMELINE_TOKEN=<a long random string>` in its environment.
3. **Expose it over HTTPS.** A Cloudflare quick tunnel needs no account:
   ```sh
   cloudflared tunnel --url http://127.0.0.1:8791 --no-autoupdate
   ```
   It prints a `https://<random>.trycloudflare.com` hostname. A freshly created
   quick tunnel can take up to ~60 s to become routable — wait and retry before
   concluding it failed. (A named tunnel on your own domain is more durable.)
4. **Keep it up.** Run `server/supervise.sh` from cron (`*/5 * * * *` and
   `@reboot`), or `server/supervise.ps1` as a Scheduled Task on Windows. It
   restarts the endpoint or tunnel if either is down.
5. **Pair your r1.** Install the creation on your r1 (QR above), open it, and on
   the pairing screen paste your endpoint URL and (if you set one) your pairing
   token. Tap **test** — it reports success, round-trip time and card count. Tap
   **save** to store them and sync. The endpoint is kept in plain storage, the
   token in the creation's secure storage, and the token is sent as an
   `Authorization: Bearer` header on every fetch.

   To re-pair later, tap the `⋯` in the header or hold the side button. The screen
   pre-fills the current values, and saving a new endpoint keeps your accumulated
   timeline.

### Installing the creation on an r1 (detail)

The creation is hosted on GitHub Pages from this repo at
<https://stoicswe.github.io/timeline-r1/index.html>, published by
`.github/workflows/pages.yml`. Rabbit's install route is a QR code that encodes
the creation descriptor as JSON:

```json
{"title":"Timeline","url":"https://stoicswe.github.io/timeline-r1/index.html","description":"A day-by-day timeline of what you've discussed with the r1 and OS3.","themeColor":"#FE5000"}
```

`docs/install-qr.png` is exactly that payload. On the r1, open the creations card,
tap **add via QR code**, and scan it. Confirm the untrusted source when asked
(the host is not Rabbit's). The same code is shown by Rabbit's own share page
(link above). Rabbit's public gallery (`rabbit.tech/creations`) is the other
install route, but listing there depends on Rabbit's own submission process and
is not something this repo controls.

## Endpoint notes

- **CORS must name `Authorization` explicitly.** `Access-Control-Allow-Headers: *`
  is *not* enough for a request carrying `Authorization` in the r1 WebView; the
  preflight fails unless the header is listed by name. `timeline-server.py` does
  this.
- **Token check.** With `TIMELINE_TOKEN` set, every request must carry
  `Authorization: Bearer <token>` or it is answered `401`. With it unset the
  endpoint stays open.

## Known limits

- The timeline refreshes only when the creation is opened **and** the machine and
  its tunnel are up. Otherwise it shows the copy already on the device.
- A quick tunnel has no uptime guarantee. A named tunnel on your own domain is
  more durable.
- An in-place creation update does not reliably reach the r1 tile promptly; a
  fresh install may be needed for the device to pick up new code.
- The creation cannot identify its owner, so each owner's backend is a separate
  installation. There is no shared feed.

## Licence

MIT — see `LICENSE`.
