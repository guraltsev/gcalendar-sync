# gcalendar-sync

Google Calendar in folders of `.ics` files, synced by [vdirsyncer](https://vdirsyncer.pimutils.org), with a
**git-versioned backup** of every state. The sibling of gmail-sync: same commands, settings, guards and timers.

- **Full sync** every 5 minutes; **quick sync** within seconds of a local change: a systemd path unit watches the two-way
  calendars, and only the changed ones are synced. Files the sync itself wrote do not start another.
  Google's own changes are found by the 5-minute sync.
- **Per calendar**: `pull` (the default) is read-only, local changes are undone by the next sync and never reach Google;
  `both` is two-way. Conflict: Google's version stays, the local one is in the backup.
- **Guards**: a two-way calendar that lost more than 10% of its events (and at least 3), a missing folder, or an emptied
  calendar stops the sync (`--force` overrides). Calendars are never created or removed in Google.
- **Secrets**: the OAuth client and token are encrypted with `systemd-creds --user`. The token is in plain text only while
  vdirsyncer runs, in `$XDG_RUNTIME_DIR` (memory, only you).
- **Change notes** for other programs, see below.

## Google side, once

`gcalendar-sync set-client ACCOUNT` explains the steps with links (project, CalDAV API, app, publish, *Desktop app* client)
and asks for the file Google lets you download at the end.

## Install and first sync

```bash
sudo dnf install vdirsyncer git
./gcalendar-sync install
gcalendar-sync init personal --email you@gmail.com --file-mode 640 --dir-mode 750
gcalendar-sync set-client personal          # explains the Google steps
gcalendar-sync authorize personal           # browser sign-in; prints the calendars
gcalendar-sync add personal main you@gmail.com
gcalendar-sync add personal secretary ID@group.calendar.google.com both
gcalendar-sync sync personal
gcalendar-sync enable-timers personal
```

`enable-timers` again after adding the first two-way calendar. `gcalendar-sync help` lists every command.
A client secret or token is not in the backup: after losing `~/.config`, `recover`, then `set-client` and `authorize`.

## Files

| Where | What |
|---|---|
| `~/Documents/Calendars/ACCOUNT/NAME/*.ics` | one event per file (a vdir: khal, Thunderbird add-ons, scripts) |
| `~/Documents/Calendars/ACCOUNT/.changes/` | change notes |
| `~/Documents/Calendars/ACCOUNT.backup.git` | backup; `history`, `restore DEST --at DATE`, `git ACCOUNT log -p` |
| `~/.config/gcalendar-sync/ACCOUNT/` | `account.conf`, `calendars.conf`, secrets, `hooks.d/` |

Do not let Syncthing sync a calendar folder to another computer that syncs it too.

## Change notes: how another program is told

After each commit, `.changes/YYYYMMDDTHHMMSS.mmmZ-COMMIT.tsv` appears at once (renamed into place):

    remote<TAB>A<TAB>main/UID.ics

`remote` (came from Google) or `local`; `A`dded, `M`odified, `D`eleted; calendar and file. Names sort by time; they are
kept 30 days. A reader remembers the last name it handled, and may watch the folder (`PathChanged=`). The file says only
*that* something changed; read the event, or the backup for a deleted one. The first sync lists every event.

## Sharing with another account

`FILE_MODE`/`DIR_MODE` (e.g. 640/750; 660/770 for an account that writes) are applied after each sync, because vdirsyncer
writes 600, which cancels an ACL share. Share the account's folder read-only and, if wanted, one two-way calendar
read-write: its events are then the only ones the other account can change.

## Hooks

`~/.config/gcalendar-sync/ACCOUNT/hooks.d/{pre-sync,post-sync,sync-failed}/*`, as in gmail-sync (yours, not writable by others;
a failing pre-sync cancels the sync), with `GCALENDAR_SYNC_ACCOUNT`, `_CALENDARS`, `_EVENT`, `_STATUS`.

## Tests

`tests/test.sh` (`VDIRSYNCER=PATH` to choose the program). A local folder stands in for Google; the real vdirsyncer runs.
The Google sign-in itself is not tested.
