# timeline-r1

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
| `install.sh` | **one-command installer** for Linux / macOS — stands up the endpoint + tunnel, verifies, prints the pairing details |
| `install.ps1` | **one-command installer** for Windows (PowerShell) — same, using a per-user Scheduled Task |
| `creation/` | the creation source — `index.html`, `style.css`, `app.js`, `icon.svg` |
| `server/timeline-server.py` | the read-only endpoint (CORS, `?since=`, optional token check) |
| `server/supervise.sh` | keeps the endpoint and tunnel up; republishes the pointer when the tunnel URL changes |
| `server/supervise.ps1` | the same supervisor for Windows |
| `server/generate-timeline.md` | spec for the OS3-side generator task |

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

### One-command install (recommended)

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
   plus a `curl`/`Invoke-WebRequest` line to verify, and the one thing only you
   can do on the OS3 side (below).

Useful flags: `--dir`, `--port`, `--token`, `--no-supervisor`, `--no-tunnel`,
`--pointer`, `--force`, `--yes`, `--dry-run` (`install.ps1` takes the same as
`-Dir`, `-Port`, …). Run `./install.sh --help` for the list.

> **One step stays manual, by design.** OS3's journal, recordings and memory are
> readable only through OS3's own tools, so the day-cards must be produced by an
> **OS3 scheduled task**, not by the installer. After installing, create a daily
> OS3 task whose prompt is the contents of
> `~/.timeline-r1/server/generate-timeline.md`; it writes
> `~/.timeline-r1/data/timeline.json`, which the endpoint serves. Until it runs
> once the timeline is empty (`/health` shows `cardCount: 0`).

### Manual setup (what the installer automates)

If you would rather do it by hand:

1. **Generate the cards.** Create an OS3 scheduled task from
   `server/generate-timeline.md`. It reads your journal, recordings and memory,
   groups by completed day, and writes `data/timeline.json`. Run it daily.
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
5. **Pair your r1.** Install the creation on your r1, open it, and on the pairing
   screen paste your endpoint URL and (if you set one) your pairing token. Tap
   **test** — it reports success, round-trip time and card count. Tap **save** to
   store them and sync. The endpoint is kept in plain storage, the token in the
   creation's secure storage, and the token is sent as an `Authorization: Bearer`
   header on every fetch.

   To re-pair later, tap the `⋯` in the header or hold the side button. The screen
   pre-fills the current values, and saving a new endpoint keeps your accumulated
   timeline.

### Installing the creation on an r1

Host `creation/` on any static HTTPS host, then open Rabbit's share link with your
address filled in (URL-encode each value):

```
https://www.rabbit.tech/share_creation?title=Timeline&description=<desc>&url=<your index.html>&themeColor=%23FE5000
```

Scan the QR code it shows with your r1, and confirm the untrusted source when
asked (the host is not Rabbit's).

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
