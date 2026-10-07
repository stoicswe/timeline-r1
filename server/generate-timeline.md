# timeline generator — OS3-side task

This is the OS3-side half of the r1 timeline creation. It is not a local script:
OS3's journal, meeting recordings and memory live in the cloud and are reachable
only through OS3's own tools, so the day-cards have to be produced by an OS3 task.
The local endpoint (`server/timeline-server.py`) only *serves* the file this task
writes.

## What it does

1. Read what Nathaniel did with the r1 / OS3 for each **completed** day since the
   last generation (never the current day in progress):
   - `device_journal_list` (+ `device_journal_read` for the bodies of notes and
     saved searches) — notes, saved searches, recordings, vision sessions.
   - `meeting_recording_list` (+ `meeting_recording_read`) — recordings and their
     summaries.
   - `recall_memory` — what was discussed, by day.
2. Group by day (UTC). One card per day that has activity.
3. Write a one-line `summary` (top level) and a longer `detail` (expanded view)
   for each card. Keep them short — the r1 screen is 240x282.
4. Write the result to `data/timeline.json` on this machine, merging with the
   existing cards so history accumulates. Never drop an existing day.

## Exclusion rule (required)

The timeline must contain only Nathaniel's **other, non-timeline** requests.
Exclude anything that is the timeline feature talking to itself:

- the creation's own fetches to the endpoint (they never enter the journal, but
  guard anyway);
- any request whose text is about refreshing, updating, syncing or viewing the
  timeline itself;
- this generator task's own run.

Match on the words `timeline`, the creation's title, the endpoint host, and
`refresh`/`sync`/`update` near `timeline`. If a day contains *only* excluded
activity, emit no card for it.

## Output shape

```json
{
  "version": 1,
  "timezone": "UTC",
  "generatedAt": "<ISO 8601 UTC>",
  "cards": [
    { "date": "YYYY-MM-DD", "summary": "...", "detail": "...", "tags": ["..."] }
  ]
}
```

Cards are sorted oldest-first. The endpoint answers `?since=YYYY-MM-DD` by
returning only cards strictly after that date, so the creation only pulls the
delta on each refresh.
