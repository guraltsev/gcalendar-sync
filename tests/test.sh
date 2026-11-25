#!/usr/bin/env bash
# Offline tests: never contact Google. A local folder stands in for it, so the real
# pairs and the real vdirsyncer (VDIRSYNCER=...) are used. KEEP=1 keeps the temp folder.
set -euo pipefail
here=$(dirname -- "$(readlink -f -- "$0")")
T=$(mktemp -d "${TMPDIR:-/tmp}/gcalendar-sync-test.XXXXXX")
trap '[[ -n ${KEEP:-} ]] && echo "kept $T" || rm -rf -- "$T"' EXIT
export HOME=$T/home XDG_CONFIG_HOME=$T/home/.config GCALENDAR_SYNC_CONFIG=$T/config GCALENDAR_SYNC_STATE=$T/state \
       GCALENDAR_SYNC_CALENDARS=$T/cal GCALENDAR_SYNC_RUNTIME=$T/run GCALENDAR_SYNC_TEST_REMOTE=$T/google GCALENDAR_SYNC_SETTLE=0
mkdir -p "$HOME"
GS=$here/../gcalendar-sync
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check()  { local d=$1; shift; if "$@" >"$T/out" 2>&1; then ok "$d"; else fail "$d"; sed 's/^/     /' "$T/out"; fi; }
refuse() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else ok "$d"; fi; }
is()     { [[ $2 == "$3" ]] && ok "$1" || fail "$1 (got '$2', want '$3')"; }
ev() { printf 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:t\r\nBEGIN:VEVENT\r\nUID:%s\r\nDTSTAMP:20260101T000000Z\r\nDTSTART:20261201T100000Z\r\nSUMMARY:%s\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' "$2" "$3" > "$1/$2.ics"; }
G=$T/google P=$T/google/me@x.com S=$T/google/sec@group.calendar.google.com L=$T/cal/a
mkdir -p "$P" "$S"
for i in 1 2 3 4 5 6; do ev "$P" "p$i" "Main $i"; ev "$S" "s$i" "Sec $i"; done
echo -n 'My secretary' > "$S/displayname"

check "init" "$GS" init a --email me@x.com --file-mode 640 --dir-mode 750
refuse "init twice" "$GS" init a --email me@x.com
refuse "bad account name" "$GS" init ../a --email me@x.com
refuse "injection in email" "$GS" init b --email 'a"b@x'
refuse "injection in path" "$GS" init b --email a@b.c --calendars $'/tmp/x\npath = "/"'
refuse "backup inside calendars" "$GS" init b --email a@b.c --calendars "$T/b" --backup-git "$T/b/.git"
refuse "sync without calendars" "$GS" sync a

is "list-calendars" "$("$GS" list-calendars a 2>/dev/null | grep sec@)" $'sec@group.calendar.google.com\tMy secretary'
refuse "bad calendar name" "$GS" add a '../x' me@x.com
check "add pull (default)" "$GS" add a main me@x.com
check "add both" "$GS" add a secretary sec@group.calendar.google.com both
refuse "same calendar twice" "$GS" add a again me@x.com
check "first sync" "$GS" sync a
is "downloaded" "$(ls "$L/main" "$L/secretary" | grep -c ics)" 12
is "file mode" "$(stat -c %a "$L/main/p1.ics")" 640
is "dir mode" "$(stat -c %a "$L/main")" 750
is "backup commit" "$("$GS" git a ls-tree -r --name-only main | grep -c 'main/p')" 6
is "change notes not in the backup" "$("$GS" git a ls-tree -r --name-only main | grep -c changes || true)" 0
is "change note: remote additions" "$(grep -hc $'^remote\tA\t' "$L"/.changes/*.tsv)" 12

# ---- both ways
ev "$L/secretary" mine "Local event"
check "quick sync" "$GS" sync a --quick
check "local event uploaded" test -f "$S/mine.ics"
n=$(ls "$L/.changes" | wc -l)
is "change note: local" "$(cat "$L"/.changes/*.tsv | grep -c $'^local\tA\tsecretary/mine.ics')" 1
is "quick with nothing changed says nothing" "$("$GS" sync a --quick 2>&1)" ""
is "and writes no note" "$(ls "$L/.changes" | wc -l)" "$n"
sleep 0.1; ev "$P" p1 "Main 1 moved"; ev "$P" new1 "Invitation"; rm "$P/p2.ics"
check "sync remote changes" "$GS" sync a
check "update arrived" grep -q moved "$L/main/p1.ics"
check "new arrived" test -f "$L/main/new1.ics"
check "removal arrived" test ! -e "$L/main/p2.ics"
is "notes" "$(cat "$(ls "$L"/.changes/*.tsv | tail -1)" | sort | tr '\t\n' '  ')" "remote A main/new1.ics remote D main/p2.ics remote M main/p1.ics "
check "quiet sync" "$GS" sync a

# ---- pull-only
sleep 0.1; ev "$L/main" p3 "Local tampering"; ev "$L/main" intruder "x"; rm "$L/main/p4.ics"
check "sync after tampering" "$GS" sync a
check "and the one after" "$GS" sync a
refuse "pull: local edit not sent" grep -q tampering "$P/p3.ics"
refuse "pull: local event not sent" test -e "$P/intruder.ics"
check "pull: local deletion not sent" test -f "$P/p4.ics"
check "the local edit is in the history" bash -c "'$GS' git a log -p main -- main/p3.ics | grep -q tampering"
is "pull: local side reverted" "$(grep -c tampering "$L/main/p3.ics" || true)-$([[ -e $L/main/p4.ics ]] && echo back)" "0-back"

# ---- conflict: Google wins, the local version is in the backup
sleep 0.1; ev "$L/secretary" s1 "LOCALVER"; ev "$S" s1 "REMOTEVER"
check "conflict" "$GS" sync a
check "Google's version stays" grep -q REMOTEVER "$L/secretary/s1.ics"
check "local version in the backup" bash -c "'$GS' git a log -p main -- secretary/s1.ics | grep -q LOCALVER"

# ---- guards
rm "$L"/secretary/s[2-6].ics
refuse "mass deletion refused" "$GS" sync a
is "nothing deleted in Google" "$(ls "$S" | grep -c ics)" 7
check "restore" "$GS" restore a "$T/restored" --rev main~1
check "restored" test -f "$T/restored/secretary/s2.ics"
refuse "restore into a full folder" "$GS" restore a "$T/restored"
check "--force" "$GS" sync a --force
is "deleted in Google" "$(ls "$S" | grep -c ics)" 2
mv "$L/secretary" "$T/away"
refuse "missing calendar folder refused" "$GS" sync a
mv "$T/away" "$L/secretary"
check "fine again" "$GS" sync a

# ---- read-only to two-way and back
conf=$T/config/a/calendars.conf; before=$(ls "$P" | grep -c ics)
sed -i 's/^main pull/main both/' "$conf"; check "regen to two-way" "$GS" regen a; check "sync" "$GS" sync a
is "nothing lost or doubled in Google" "$(ls "$P" | grep -c ics)" "$before"
ev "$L/main" fromhere x; check "sync" "$GS" sync a; check "now sent to Google" test -f "$P/fromhere.ics"
sed -i 's/^main both/main pull/' "$conf"; rm "$P/fromhere.ics"; check "regen to read-only" "$GS" regen a; check "sync" "$GS" sync a; check "sync" "$GS" sync a
refuse "a removal in Google is not undone" test -e "$P/fromhere.ics"; refuse "and arrives here" test -e "$L/main/fromhere.ics"
is "Google as before" "$(ls "$P" | grep -c ics)" "$before"

# ---- hooks, lock, move, remove, recover
H=$T/config/a/hooks.d; mkdir -p "$H/post-sync" "$H/pre-sync" "$H/sync-failed"
printf '#!/bin/sh\necho "$GCALENDAR_SYNC_ACCOUNT $GCALENDAR_SYNC_EVENT" > %s/hook\n' "$T" > "$H/post-sync/x"; chmod 700 "$H/post-sync/x"
check "sync with a hook" "$GS" sync a; is "hook ran" "$(cat "$T/hook")" "a post-sync"
chmod 770 "$H/post-sync/x"; rm "$T/hook"; "$GS" sync a >/dev/null 2>&1; refuse "writable hook refused" test -e "$T/hook"
printf '#!/bin/sh\nexit 1\n' > "$H/pre-sync/no"; chmod 700 "$H/pre-sync/no"
refuse "pre-sync cancels" "$GS" sync a; rm "$H/pre-sync/no"
rc=0; flock "$T/state/a/lock" "$GS" sync a >/dev/null 2>&1 || rc=$?; is "locked" "$rc" 75
check "maint" "$GS" maint a
check "status" "$GS" status
check "history" "$GS" history a 3
check "move" "$GS" move a --calendars "$T/cal2"
check "sync after move" "$GS" sync a; check "moved" test -f "$T/cal2/secretary/mine.ics"
is "move changed nothing in Google" "$(ls "$P" | grep -c ics)" 6
check "remove" "$GS" remove a secretary
check "files stay" test -f "$T/cal2/secretary/mine.ics"
check "Google stays" test -f "$S/mine.ics"
mkdir -p "$T/gone"; mv "$T/config/a" "$T/gone/"; mv "$T/state/a" "$T/gone/state"
refuse "init refuses the old backup" "$GS" init a --email me@x.com --calendars "$T/new"
check "recover" "$GS" recover a --email me@x.com --calendars "$T/cal2"
is "history kept" "$("$GS" git a rev-list --count main | awk '{print ($1>5)}')" 1

# ---- secrets
printf 'cid.apps\nsecret-xyz\n' | "$GS" set-client a --stdin >/dev/null 2>"$T/out" && {
    is "client id" "$("$here/../bin/gcalendar-sync-secret" a id)" cid.apps
    is "client secret" "$("$here/../bin/gcalendar-sync-secret" a secret)" secret-xyz
    refuse "not in plain text" grep -rq secret-xyz "$T/config"
    chmod 640 "$T/config/a/client.cred"; refuse "refuses a readable secret" "$here/../bin/gcalendar-sync-secret" a id
    chmod 600 "$T/config/a/client.cred"
    out=$(env -u GCALENDAR_SYNC_TEST_REMOTE "$GS" list-calendars a 2>&1 || true)
    [[ $out == *"authorize"* ]] && ok "not signed in: says so" || fail "not signed in: $out"
    env -u GCALENDAR_SYNC_TEST_REMOTE "$GS" add a main2 x@y.z >/dev/null 2>&1
    check "real config names Google" grep -q 'type = "google_calendar"' "$T/config/a/vdirsyncer.conf"
    refuse "no secret in the config" grep -q secret-xyz "$T/config/a/vdirsyncer.conf"
} || { echo "skip secrets (systemd-creds --user does not work here)"; cat "$T/out"; }

echo '{"installed":{"client_id":"jid.apps","project_id":"p","client_secret":"jsec-1","redirect_uris":["http://localhost"]}}' > "$T/c s.json"
check "set-client --json" "$GS" set-client a --json "$T/c s.json"
is "id from the file" "$("$here/../bin/gcalendar-sync-secret" a id)" jid.apps
is "secret from the file" "$("$here/../bin/gcalendar-sync-secret" a secret)" jsec-1
check "path as dragged into a terminal" "$GS" set-client a --json "'$T/c s.json' "
echo x > "$T/config/a/token.cred"; chmod 600 "$T/config/a/token.cred"
check "same client again" "$GS" set-client a --json "$T/c s.json"; check "keeps the sign-in" test -e "$T/config/a/token.cred"
sed 's/jid/other/' "$T/c s.json" > "$T/c2.json"; check "another client" "$GS" set-client a --json "$T/c2.json"
refuse "removes the old sign-in" test -e "$T/config/a/token.cred"
echo '{"web":{"client_id":"x","client_secret":"y"}}' > "$T/web.json"
refuse "wrong client type refused" "$GS" set-client a --json "$T/web.json"
refuse "missing file refused" "$GS" set-client a --json "$T/none.json"
out=$(python3 -c 'import os,pty,sys
pid,fd=pty.fork()
if pid==0: os.execv(sys.argv[1],sys.argv[1:])
os.write(fd,b"\n"); b=b""
try:
    while (x:=os.read(fd,4096)): b+=x
except OSError: pass
sys.stdout.write(b.decode())' "$GS" set-client a 2>&1) || true
[[ $out == *"auth/overview/personal"*"Desktop app"*"CalDAV API"*"nothing was stored"* ]] && ok "set-client explains itself" || fail "guide: $out"

# ==================================================== help and usage errors ===
for c in $("$GS" help | sed -nE 's/^  ([a-z][a-z-]+) .*/\1/p' | sort -u); do
    out=$("$GS" "$c" --help 2>&1) && [[ $out == "usage: gcalendar-sync $c"* ]] && ok "$c --help" || fail "$c --help: $out"
done
is "every command is in the overview" "$("$GS" help | sed -nE 's/^  ([a-z][a-z-]+)( .*)?$/\1/p' | sort -u | paste -sd' ')" \
    "$("$GS" nonsense 2>&1 | sed -n 's/^commands: //p' | tr ' ' '\n' | sort | paste -sd' ')"
for a in "init -h" "init help" "help init" "init x --email a@b.c --help"; do
    out=$("$GS" $a 2>&1) && [[ $out == *"usage: gcalendar-sync init ACCOUNT"*"--email ADDR"*"Example"* ]] && ok "$a" || fail "$a: $out"
done
refuse "help created no account" test -e "$GCALENDAR_SYNC_CONFIG/help"
refuse "nor did --help" test -e "$GCALENDAR_SYNC_CONFIG/x"
usage_error() { # DESCRIPTION EXPECTED ARGS...
    local d=$1 want=$2 rc=0; shift 2
    out=$(setsid -w "$GS" "$@" 2>&1 </dev/null) || rc=$?
    [[ $rc == 2 && $out == *"$want"* && $out == *"usage: gcalendar-sync $1"* && $out == *"gcalendar-sync help $1"* ]] && ok "$d" || fail "$d ($rc): $out"
}
usage_error "init without a name" "needs a name" init
usage_error "init without an address" "--email ADDR is required" init nomail
usage_error "init with a bad address" "nope" init nomail --email nope
usage_error "init with an option for a name" "usage" init --email a@b.c
usage_error "init with a bad name" "invalid account name" init 'A b' --email a@b.c
usage_error "option without a value" "--email needs a value" init nomail --email
usage_error "unknown option" "unknown option '--nope'" init nomail --nope
usage_error "a command that cannot guess the account" "needs an account" history
check "second account" "$GS" init second --email s@x.com
usage_error "sync with two accounts" "needs an account" sync
refuse "unknown command" "$GS" synch

# ========================================================= guidance ===
# Fresh homes; "signed in" needs no Google here, so a stand-in systemctl says what is enabled.
mkdir -p "$T/bin"; printf '#!/bin/sh\ncase "$*" in *is-enabled*) test -e %s/enabled ;; *"enable --now"*) touch %s/enabled ;; esac\n' "$T" "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
export PATH=$T/bin:$PATH GCALENDAR_SYNC_CONFIG=$T/g/c GCALENDAR_SYNC_STATE=$T/g/s GCALENDAR_SYNC_CALENDARS=$T/g/cal GCALENDAR_SYNC_TEST_REMOTE=$T/g/google
mkdir -p "$T/g/google/me@x.com" "$T/g/google/team@group"; echo -n 'Team; meetings' > "$T/g/google/team@group/displayname"
for i in 1 2 3; do ev "$T/g/google/me@x.com" "m$i" "x"; ev "$T/g/google/team@group" "t$i" "x"; done
says() { local d=$1 want=$2; shift 2; out=$("$@" 2>&1 </dev/null) || true; [[ $out == *"$want"* ]] && ok "$d" || fail "$d: $out"; }
says "nothing yet: points to setup" "Next:  gcalendar-sync setup" "$GS"
says "status too" "Next:  gcalendar-sync setup" "$GS" status
says "an account command without accounts too" "gcalendar-sync setup" "$GS" sync
says "setup without a terminal says so" "needs a terminal" "$GS" setup
says "real Google: registration is next" "Next:  gcalendar-sync set-client b" env -u GCALENDAR_SYNC_TEST_REMOTE "$GS" init b --email a@b.c
says "status shows what is missing" "[ ] registered with Google" env -u GCALENDAR_SYNC_TEST_REMOTE "$GS"
mv "$T/g/c" "$T/g/c.old"
pty() { python3 -c '
import os,pty,select,sys,time
answers=sys.argv[1].encode().decode("unicode_escape").split("|")
pid,fd=pty.fork()
if pid==0: os.execvp(sys.argv[2],sys.argv[2:])
out=b""; end=time.time()+60; last=time.time()
while time.time()<end:
    if select.select([fd],[],[],0.2)[0]:
        try: x=os.read(fd,4096)
        except OSError: break
        if not x: break
        out+=x; last=time.time()
    elif answers and time.time()-last>0.5 and out.rstrip().endswith(b":"):
        os.write(fd,answers.pop(0).encode()+b"\n"); last=time.time()
else: os.kill(pid,9)
sys.stdout.write(out.decode(errors="replace").replace("\r",""))' "$@"; }
# name | address (a wrong one first) | shared rw | calendars 9 (none such), 1, 2 | names, two-way | stop before the timers
out=$(pty 'work|nope|me@x.com|w|9 1 2||n|team|y|n' "$GS" setup)
[[ $out == *"not an address"*"no number '9'"* ]] && ok "setup checks answers" || fail "setup: $out"
is "setup: one calendar of each kind" "$(grep -v '^#' "$T/g/c/work/calendars.conf" | awk '{print $2}' | sort | paste -sd' ')" "both pull"
is "setup synced" "$(find "$T/g/cal/work" -name '*.ics' | wc -l)" 6
is "setup: shared permissions" "$(sed -n 's/^FILE_MODE=//p' "$T/g/c/work/account.conf")" 660
says "stopped before the timers: that is next" "Next:  gcalendar-sync enable-timers work" "$GS"
out=$(pty 'y' "$GS" setup); [[ $out == *"Everything works; nothing to do."* ]] && ok "setup continues and finishes" || fail "continue: $out"
says "all done" "Everything works" "$GS" status
out=$(pty 'x' "$GS" setup); [[ $out == *"Everything works"* && $out != *"Google address"* ]] && ok "setup again asks nothing" || fail "again: $out"
check "the only account may be left out" "$GS" sync
C=$T/g/cal/work; D=$(awk '$2=="both"{print $1}' "$T/g/c/work/calendars.conf")
ev "$C/$D" n1 x; check "sync an event" "$GS" sync; rm "$C/$D"/*.ics
"$GS" sync >/dev/null 2>&1 || true
says "a refused sync: the reason" "refusing to delete" "$GS" status
says "... as a problem" "PROBLEM" "$GS" status
says "... and what to do" "Next:  gcalendar-sync sync work" "$GS" status
check "force" "$GS" sync --force
says "fine again" "Everything works" "$GS" status
touch -d '4 hours ago' "$T/g/s/work/last-failure"; touch -d '3 hours ago' "$T/g/s/work/last-sync"
says "no sync for long" "no sync for 3 hours" "$GS" status
touch "$T/g/s/work/signin-expired"
says "expired sign-in" "Next:  gcalendar-sync authorize work" "$GS" status
check "no arguments: exit 0" "$GS"

(( fails == 0 )) && echo "all passed" || { echo "$fails failed"; exit 1; }
