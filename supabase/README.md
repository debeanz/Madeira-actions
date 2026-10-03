# Compatibility database

The website (`docs/`) and the app's **Report Compatibility** button store
reports in a free [Supabase](https://supabase.com) project. Setting one up
takes a few minutes and needs no card.

1. Sign in at supabase.com (Continue with GitHub works) and create a project.
   Any name and region; keep the database password somewhere safe.
2. Open **SQL Editor → New query**, paste all of [`schema.sql`](schema.sql),
   and press **Run**.
3. Copy two values:
   - **Project URL** — `https://<something>.supabase.co` (the project's
     **Connect** button, or **Project Settings → Data API**)
   - **Publishable key** — `sb_publishable_…`, under **Project Settings →
     API Keys**. A legacy **anon** key (a long `eyJ…` string) works too, but
     Supabase retires those at the end of 2026.

   Both are meant to be public. What they allow is fixed by `schema.sql`:
   filing and reading reports, and uploading (never reading) logs. Never use
   the **secret** / **service_role** key here — that one bypasses all of it.
4. Put them in [`docs/config.js`](../docs/config.js) for the website and in
   `ReportService` (`app/Madeira/LauncherView.swift`) for the app.

## Day to day

- **Logs** are in **Storage → logs**: a folder per game, named like its page
  on the site, holding one plain-text file per report that attached a log —
  `<date> <game> <report id>.txt`. The report's id is in the **reports** table.
  The dashboard can't preview text: **Download**, then double-click.
- **Spam** — delete the row in **Table Editor → reports**; the website drops it
  on the next load.
- **Pausing** — Supabase pauses free projects after a week without traffic.
  `.github/workflows/compat-keepalive.yml` reads one row every three days so
  that does not happen.
