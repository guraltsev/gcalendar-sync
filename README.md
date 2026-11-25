# gcalendar-sync

Google Calendar in folders of `.ics` files, synced by [vdirsyncer](https://vdirsyncer.pimutils.org), with a
**git-versioned backup** of every state. The sibling of gmail-sync: same commands, settings, guards and timers.

- **Full sync** every 5 minutes; **quick sync** within seconds of a local change: a systemd path unit watches the two-way
  calendars, and only the changed ones are synced. Files the sync itself wrote do not start another.
  Google's own changes are found by the 5-minute sync.
- **Per calendar**: `pull` (the default) is read-only, local changes are undone by the next sync and never reach Google;
  `both` is two-way. Changed on both sides: Google's version stays, the local one is in the backup. Deleted on one side and
  changed on the other: the changed event comes back.
- **Emptied calendar**: with fewer than 5 events it is simply emptied on the other side too; with more, that calendar is not
  synced until you say so (`--force`).
- **Guards**: a two-way calendar that lost more than 10% of its events (and at least 3), a missing folder, or an emptied
  calendar stops the sync (`--force` overrides). Calendars are never created or removed in Google.
- **Secrets**: the OAuth client and token are encrypted with `systemd-creds --user`. The token is in plain text only while
  vdirsyncer runs, in `$XDG_RUNTIME_DIR` (memory, only you).
- **Change notes** for other programs, see below.

## Start

```bash
sudo dnf install vdirsyncer git
./gcalendar-sync install
gcalendar-sync setup
```

`setup` guides you through everything: the account, Google's registration (a Personal mode app, explained step by step with links), the
sign-in, choosing calendars, the first sync, the timers. Stop at any time; run it again to continue.

To upgrade, run `gcalendar-sync install` from anywhere: the checkout is remembered. It fetches and says when upstream is newer;
`gcalendar-sync install --ff` pulls (fast-forward only) and installs that, and says what to solve where that is not possible.

Lost? `gcalendar-sync` alone (or `status`) shows which steps are done, what is wrong, and the command to run next.
`gcalendar-sync help`, and `COMMAND --help`, for the rest. With one account its name may be left out.

Each step as a command of its own: `init`, `set-client`, `authorize`, `add`, `sync`, `enable-timers`.
After losing `~/.config`: `setup` again with the same account name; it continues the backup's history. The client and the
sign-in are not in the backup.

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

## Links to events, for notes

    [Committee meeting](calendar-event:UID?date=2027-01-11)

`gcalendar-sync find committee` prints such links. The UID is the event's own, the same in every calendar program, so the link
does not depend on Google; it stays right when the event is moved or renamed. The date is for the reader, and used only if
the event is gone. `install` makes `gcalendar-sync open` the program for them: it shows the event and opens its day in Google
Calendar. They work on computers where it is installed, not on the phone. A calendar with repeating events opens the first date.

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
