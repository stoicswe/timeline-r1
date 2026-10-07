# timeline-r1 — the one OS3 paste

This file is the **single OS3-side step** of the timeline-r1 setup. The installer
prints it and saves it here; you paste it once into OS3 (your OS3 chat / rabbit
hole) and OS3 creates the daily generator schedule for you. After that the whole
pipeline is live.

It is self-contained: it carries the full generator spec, the exact output path
on this machine, and the schedule, so OS3 needs nothing else from you.

---

Create a **recurring OS3 scheduled task** for me and reply with its id and next
fire time. Do not ask me questions — everything you need is below.

**Schedule:** every day at 08:00 UTC (`0 8 * * *`), recurring, no end date.

**Task prompt (use this text verbatim as the scheduled task's prompt):**

> Generate the r1 timeline day-cards for my "Timeline" creation.
>
> 1. Read the existing feed at `{{DATA_FILE}}` on this machine and note the
>    newest card date.
> 2. Gather what I did with the r1 / OS3 for **completed** days only (never the
>    current day in progress), from the last card date up to yesterday (UTC),
>    using OS3's own tools:
>    - `device_journal_list` (and `device_journal_read` for note/search bodies)
>    - `meeting_recording_list` (and `meeting_recording_read` for summaries)
>    - `recall_memory` for what was discussed, by day
> 3. For each completed day with activity, write one card:
>    `{"date":"YYYY-MM-DD","summary":"one short line","detail":"a few sentences","tags":[...]}`.
>    Keep them short — the r1 screen is 240x282.
> 4. **Exclude** anything that is the timeline feature talking to itself: the
>    creation's own endpoint fetches, and any request about
>    refreshing/syncing/updating/viewing the timeline itself or this generator.
>    Include only my other, non-timeline requests. If a day has only excluded
>    activity, emit no card for it.
> 5. Merge with the existing cards (never drop an existing day) and write the
>    whole feed back to `{{DATA_FILE}}` with a fresh `generatedAt` (ISO 8601
>    UTC), keeping the shape
>    `{"version":1,"timezone":"UTC","generatedAt":...,"cards":[...]}` sorted
>    oldest-first.
> 6. Confirm the local endpoint still answers:
>    `curl -s http://127.0.0.1:{{PORT}}/health`. If it is down, run
>    `{{BASE}}/server/supervise.sh` once and re-check.
> 7. Report which days were added or updated and the current card count. If no
>    new completed day had activity, say so and change nothing.

**Why this must run in OS3:** the journal, meeting recordings and memory live in
OS3's cloud and are reachable only through OS3's own tools, so a plain script on
this machine cannot build the feed. This scheduled task is the only part of the
setup that cannot be automated locally; everything else is done by the installer.
