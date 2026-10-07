#!/bin/bash
set -eu

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gui-lock-tests.XXXXXX")
SCRIPT="$(cd "$(dirname "$0")" && pwd)/gui-lock"
export GUI_LOCK_ROOT="$ROOT"
export GUI_LOCK_POLL_SECONDS=1
export GUI_LOCK_TEST_MODE=1
trap 'rm -rf "$ROOT"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  file="$1"; text="$2"
  grep -F "$text" "$file" >/dev/null || fail "$file does not contain: $text"
}
reset_state() {
  rm -rf "$ROOT/.gui.lock" "$ROOT/.gui.lock.guard" "$ROOT/.gui.lock.guard.stale-"* \
    "$ROOT/.gui.queue" "$ROOT"/*.xcresult "$ROOT"/run-*
  rm -f "$ROOT/xcodebuild" "$ROOT/WaveWranglerUITests-Runner"
  mkdir -p "$ROOT/.gui.queue/required" "$ROOT/.gui.queue/pr" "$ROOT/.gui.queue/full" "$ROOT/.gui.queue/perf"
  : > "$ROOT/gui-lock.log"
  : > "$ROOT/order"
}
run_lane() {
  lane="$1"; class="$2"; seconds="$3"; queue_timeout="${4:-10}"
  dir="$ROOT/run-$lane"
  "$SCRIPT" run --lane "$lane" --class "$class" --pr 1 --sha test --dir "$dir" \
    --lease-minutes 1 --queue-timeout "$queue_timeout" --result "$dir/result.xcresult" -- \
    bash -c 'sleep "$1"; echo "$2" >> "$3"; mkdir -p "$4"; echo completed' _ \
      "$seconds" "$lane" "$ROOT/order" "$dir/result.xcresult"
}
run_lane_in_dir() {
  lane="$1"; class="$2"; seconds="$3"; dir="$4"; queue_timeout="${5:-10}"
  "$SCRIPT" run --lane "$lane" --class "$class" --pr 1 --sha test --dir "$dir" \
    --lease-minutes 1 --queue-timeout "$queue_timeout" --result "$dir/result-$lane.xcresult" -- \
    bash -c 'sleep "$1"; echo "$2" >> "$3"; mkdir -p "$4"; echo completed' _ \
      "$seconds" "$lane" "$ROOT/order" "$dir/result-$lane.xcresult"
}
wait_for_holder() {
  lane="$1"
  for attempt in $(seq 1 20); do
    grep -F "lane=$lane" "$ROOT/.gui.lock/owner" > /dev/null 2>&1 && return 0
    sleep 1
  done
  fail "holder $lane was not acquired"
}
wait_for_run() {
  lane="$1"
  for attempt in $(seq 1 20); do
    owner="$ROOT/.gui.lock/owner"
    pids_file=$(sed -n 's/^pids_file=//p' "$owner" 2>/dev/null || true)
    grep -F "lane=$lane" "$owner" > /dev/null 2>&1 &&
      [ -n "$pids_file" ] && [ -s "$pids_file" ] && return 0
    sleep 1
  done
  fail "run $lane did not start"
}
wait_for_ticket() {
  lane="$1"
  for attempt in $(seq 1 20); do
    find "$ROOT/.gui.queue" -type f -path "*/[0-9]*-$lane/ticket" -print -quit |
      grep -q . && return 0
    sleep 1
  done
  fail "ticket $lane was not enqueued"
}
stop_waiter() {
  lane="$1"; parent_pid="$2"
  wait_for_ticket "$lane"
  ticket_file=$(find "$ROOT/.gui.queue" -type f -path "*/[0-9]*-$lane/ticket" -print -quit)
  ticket_pid=$(sed -n 's/^owner_pid=//p' "$ticket_file")
  [ -n "$ticket_pid" ] || fail "waiter ticket $lane has no owner PID"
  kill "$ticket_pid" 2>/dev/null || true
  wait "$parent_pid" 2>/dev/null || true
}
expire_current_lease() {
  owner="$ROOT/.gui.lock/owner"
  sed 's/^expires=.*/expires=0/' "$owner" > "$owner.expired"
  mv "$owner.expired" "$owner"
}

echo "test: one run and result collection"
reset_state
run_lane single pr 0 > "$ROOT/single.out"
assert_contains "$ROOT/single.out" "ACQUIRED lane=single class=pr"
assert_contains "$ROOT/single.out" "RELEASED lane=single"
[ "$(cat "$ROOT/order")" = single ] || fail "single run did not execute"

echo "test: concurrent FIFO and priority ordering"
reset_state
run_lane holder pr 8 > "$ROOT/holder.out" 2>&1 &
holder_pid=$!
wait_for_run holder
run_lane first-pr pr 0 > "$ROOT/first-pr.out" 2>&1 &
first_pr_pid=$!
wait_for_ticket first-pr
run_lane perf perf 0 > "$ROOT/perf.out" 2>&1 &
perf_pid=$!
wait_for_ticket perf
run_lane full full 0 > "$ROOT/full.out" 2>&1 &
full_pid=$!
wait_for_ticket full
run_lane required required 0 > "$ROOT/required.out" 2>&1 &
required_pid=$!
wait_for_ticket required
run_lane second-pr pr 0 > "$ROOT/second-pr.out" 2>&1 &
second_pr_pid=$!
wait_for_ticket second-pr
wait "$holder_pid" "$first_pr_pid" "$perf_pid" "$full_pid" "$required_pid" "$second_pr_pid"
expected=$(printf 'holder\nrequired\nfirst-pr\nsecond-pr\nperf\nfull')
[ "$(cat "$ROOT/order")" = "$expected" ] || fail "priority/FIFO order was: $(tr '\n' ' ' < "$ROOT/order")"

echo "test: status visibility"
reset_state
run_lane visible pr 3 > "$ROOT/visible.out" 2>&1 &
visible_pid=$!
sleep 1
run_lane queued full 0 > "$ROOT/queued.out" 2>&1 &
queued_pid=$!
for attempt in $(seq 1 20); do
  "$SCRIPT" status > "$ROOT/status.out"
  grep -F "QUEUE position=1 class=full lane=queued" "$ROOT/status.out" > /dev/null && break
  sleep 1
done
assert_contains "$ROOT/status.out" "HOLDER lane=visible class=pr"
assert_contains "$ROOT/status.out" "QUEUE position=1 class=full lane=queued"
assert_contains "$ROOT/status.out" "eta="
wait "$visible_pid" "$queued_pid"

seed_owner() {
  reason="$1"
  mkdir -p "$ROOT/.gui.lock"
  current=$(date +%s)
  acquired=$((current - 120))
  expires=$((current + 60))
  pid=""
  if [ "$reason" = expired ]; then
    expires=$((current - 1))
    pid="$$"
  fi
  [ "$reason" = dead ] && pid=999999
  [ "$reason" = acquiring ] && acquired="$current"
  cat > "$ROOT/.gui.lock/owner" <<EOF
token=seed
lane=stale-$reason
class=pr
pr=1
sha=old
dir=$ROOT/stale-$reason
pid=$pid
pids_file=$ROOT/stale-$reason/pids
output=$ROOT/stale-$reason/output
result=$ROOT/stale-$reason/result.xcresult
host=test
acquired=$acquired
heartbeat=$((current - 120))
expires=$expires
lease_seconds=60
EOF
}

seed_legacy_owner() {
  lane="$1"; pid="$2"; start="$3"
  mkdir -p "$ROOT/.gui.lock"
  cat > "$ROOT/.gui.lock/owner" <<EOF
lane=$lane
pr=1
sha=old
dir=$ROOT/legacy-$lane
pid=$pid
start=$start
host=test
EOF
}

echo "test: expired lease reclamation"
reset_state
seed_owner expired
run_lane expired-reclaimer pr 0 > "$ROOT/expired.out"
assert_contains "$ROOT/expired.out" "RECLAIMED lane=stale-expired reason=lease expired"
assert_contains "$ROOT/gui-lock.log" "reclaimed lane=stale-expired"

echo "test: dead PID reclamation"
reset_state
seed_owner dead
run_lane dead-reclaimer pr 0 > "$ROOT/dead.out"
assert_contains "$ROOT/dead.out" "RECLAIMED lane=stale-dead reason=recorded pid 999999 is dead"
assert_contains "$ROOT/gui-lock.log" "reclaimed lane=stale-dead"

echo "test: acquiring owner with an empty PID has a reclaim grace"
reset_state
seed_owner acquiring
run_lane acquiring-waiter pr 0 > "$ROOT/acquiring-waiter.out" 2>&1 &
acquiring_waiter_pid=$!
sleep 2
[ -d "$ROOT/.gui.lock" ] || fail "empty-PID owner was reclaimed during acquisition grace"
if grep -F "reclaimed lane=stale-acquiring" "$ROOT/gui-lock.log" > /dev/null; then
  fail "waiter reclaimed an acquiring owner"
fi
stop_waiter acquiring-waiter "$acquiring_waiter_pid"

echo "test: tokenless legacy dead holder is reclaimed"
reset_state
seed_legacy_owner legacy-dead 999999 "$(date +%s)"
run_lane legacy-reclaimer pr 0 > "$ROOT/legacy-dead.out"
assert_contains "$ROOT/legacy-dead.out" "RECLAIMED lane=legacy-dead reason=legacy owner pid 999999 is dead"

echo "test: live legacy holder survives until release"
reset_state
seed_legacy_owner legacy-live "$$" "$(( $(date +%s) - 60 ))"
run_lane legacy-waiter pr 0 > "$ROOT/legacy-waiter.out" 2>&1 &
legacy_waiter_pid=$!
sleep 2
[ "$(sed -n 's/^lane=//p' "$ROOT/.gui.lock/owner")" = legacy-live ] ||
  fail "live legacy holder was reclaimed"
stop_waiter legacy-waiter "$legacy_waiter_pid"

echo "test: legacy hard maximum with no xcodebuild"
reset_state
seed_legacy_owner legacy-overdue "$$" "$(( $(date +%s) - 2701 ))"
run_lane legacy-overdue-reclaimer pr 0 > "$ROOT/legacy-overdue.out"
assert_contains "$ROOT/legacy-overdue.out" "RECLAIMED lane=legacy-overdue reason=legacy holder exceeded 45 min"

echo "test: overdue legacy holder with live xcodebuild is protected"
reset_state
ln -s /bin/sleep "$ROOT/xcodebuild"
"$ROOT/xcodebuild" 6 &
legacy_build_pid=$!
seed_legacy_owner legacy-building "$legacy_build_pid" "$(( $(date +%s) - 2701 ))"
run_lane legacy-build-waiter pr 0 > "$ROOT/legacy-build-waiter.out" 2>&1 &
legacy_build_waiter_pid=$!
sleep 2
[ "$(sed -n 's/^lane=//p' "$ROOT/.gui.lock/owner")" = legacy-building ] ||
  fail "overdue legacy holder with live xcodebuild was reclaimed"
stop_waiter legacy-build-waiter "$legacy_build_waiter_pid"
wait "$legacy_build_pid"
run_lane legacy-build-reclaimer pr 0 > "$ROOT/legacy-build-reclaimer.out"
assert_contains "$ROOT/legacy-build-reclaimer.out" "RECLAIMED lane=legacy-building reason=legacy owner pid"

echo "test: empty legacy PID uses start for acquisition grace"
reset_state
seed_legacy_owner legacy-acquiring "" "$(date +%s)"
run_lane legacy-acquiring-waiter pr 0 > "$ROOT/legacy-acquiring-waiter.out" 2>&1 &
legacy_acquiring_pid=$!
sleep 2
[ -d "$ROOT/.gui.lock" ] || fail "empty legacy PID was reclaimed during grace"
stop_waiter legacy-acquiring-waiter "$legacy_acquiring_pid"
reset_state
seed_legacy_owner legacy-empty "" "$(( $(date +%s) - 121 ))"
run_lane legacy-empty-reclaimer pr 0 > "$ROOT/legacy-empty.out"
assert_contains "$ROOT/legacy-empty.out" "RECLAIMED lane=legacy-empty reason=legacy owner pid is missing after acquisition grace"

echo "test: orphaned acquire parent cannot expose a live wrapper lease"
reset_state
( run_lane durable-owner pr 10; : ) > "$ROOT/durable-owner.out" 2>&1 &
acquire_parent_pid=$!
wait_for_run durable-owner
durable_pid=$(sed -n 's/^pid=//p' "$ROOT/.gui.lock/owner")
[ "$durable_pid" != "$acquire_parent_pid" ] || fail "lease owner was the short-lived acquire parent"
kill -9 "$acquire_parent_pid"
wait "$acquire_parent_pid" 2>/dev/null || true
kill -0 "$durable_pid" 2>/dev/null || fail "wrapper died with its acquire parent"
run_lane durable-waiter pr 0 > "$ROOT/durable-waiter.out" 2>&1 &
durable_waiter_pid=$!
wait_for_ticket durable-waiter
sleep 2
[ "$(sed -n 's/^lane=//p' "$ROOT/.gui.lock/owner")" = durable-owner ] ||
  fail "live wrapper lease was stolen after acquire parent died"
wait "$durable_waiter_pid"
assert_contains "$ROOT/durable-owner.out" "RELEASED lane=durable-owner"
assert_contains "$ROOT/durable-waiter.out" "RELEASED lane=durable-waiter"

echo "test: host xcodebuild blocks acquisition without dropping ticket"
reset_state
ln -s /bin/bash "$ROOT/xcodebuild"
"$ROOT/xcodebuild" -c 'sleep 7; :' test-without-building &
active_build_pid=$!
run_lane host-blocked pr 0 1 > "$ROOT/host-blocked.out" 2>&1 &
host_blocked_pid=$!
wait_for_ticket host-blocked
sleep 2
[ ! -d "$ROOT/.gui.lock" ] || fail "new lease acquired while host xcodebuild was active"
"$SCRIPT" status > "$ROOT/host-blocked-status.out"
assert_contains "$ROOT/host-blocked-status.out" "QUEUE position=1 class=pr lane=host-blocked"
assert_contains "$ROOT/gui-lock.log" "blocked: active xcodebuild pid $active_build_pid"
wait "$active_build_pid" "$host_blocked_pid"
assert_contains "$ROOT/host-blocked.out" "WAIT queue timeout; ticket retained in place"
assert_contains "$ROOT/host-blocked.out" "RELEASED lane=host-blocked"

echo "test: active host xcodebuild prevents stale reclaim"
reset_state
seed_owner expired
ln -s /bin/bash "$ROOT/xcodebuild"
"$ROOT/xcodebuild" -c 'sleep 7; :' test-without-building &
active_reclaim_pid=$!
run_lane reclaim-blocked pr 0 > "$ROOT/reclaim-blocked.out" 2>&1 &
reclaim_blocked_pid=$!
wait_for_ticket reclaim-blocked
sleep 2
[ "$(sed -n 's/^token=//p' "$ROOT/.gui.lock/owner")" = seed ] ||
  fail "stale lease reclaimed while host xcodebuild was active"
assert_contains "$ROOT/gui-lock.log" "blocked: active xcodebuild pid $active_reclaim_pid"
wait "$active_reclaim_pid" "$reclaim_blocked_pid"
assert_contains "$ROOT/reclaim-blocked.out" "RECLAIMED lane=stale-expired"

echo "test: active UI test runner also blocks acquisition"
reset_state
ln -s /bin/bash "$ROOT/WaveWranglerUITests-Runner"
"$ROOT/WaveWranglerUITests-Runner" -c 'sleep 7; :' runner &
active_runner_pid=$!
run_lane runner-blocked pr 0 > "$ROOT/runner-blocked.out" 2>&1 &
runner_blocked_pid=$!
wait_for_ticket runner-blocked
sleep 2
[ ! -d "$ROOT/.gui.lock" ] || fail "new lease acquired while UI test runner was active"
assert_contains "$ROOT/gui-lock.log" "blocked: active xcodebuild pid $active_runner_pid"
wait "$active_runner_pid" "$runner_blocked_pid"
assert_contains "$ROOT/runner-blocked.out" "RELEASED lane=runner-blocked"

echo "test: queue timeout retains position"
reset_state
run_lane timeout-holder pr 4 > "$ROOT/timeout-holder.out" 2>&1 &
timeout_holder_pid=$!
wait_for_run timeout-holder
run_lane timeout-waiter pr 0 1 > "$ROOT/timeout-waiter.out" 2>&1 &
timeout_waiter_pid=$!
for attempt in $(seq 1 20); do
  "$SCRIPT" status > "$ROOT/timeout-status.out"
  grep -F "QUEUE position=1 class=pr lane=timeout-waiter" "$ROOT/timeout-status.out" > /dev/null && break
  sleep 1
done
assert_contains "$ROOT/timeout-status.out" "QUEUE position=1 class=pr lane=timeout-waiter"
wait "$timeout_holder_pid" "$timeout_waiter_pid"
assert_contains "$ROOT/timeout-waiter.out" "WAIT queue timeout; ticket retained in place"
assert_contains "$ROOT/gui-lock.log" "requeued in place"

echo "test: hard lease maximum"
if "$SCRIPT" run --lane invalid --class pr --sha test --dir "$ROOT/invalid" --lease-minutes 46 -- true > /dev/null 2>&1; then
  fail "46-minute lease was accepted"
fi

echo "test: Products argument never targets the wrapper"
reset_state
products_arg="$ROOT/run-products/Products/WaveWranglerUITests.xctestrun"
mkdir -p "$(dirname "$products_arg")"
"$SCRIPT" run --lane products --class pr --pr 1 --sha test --dir "$ROOT/run-products" \
  --lease-minutes 1 --result "$ROOT/run-products/result.xcresult" -- \
  bash -c 'sleep 1; mkdir -p "$2"; echo completed' _ "$products_arg" "$ROOT/run-products/result.xcresult" > "$ROOT/products.out"
assert_contains "$ROOT/products.out" "RELEASED lane=products"

echo "test: expired silent run is terminated without renewal"
reset_state
export GUI_LOCK_TEST_LEASE_SECONDS=2
run_lane silent pr 20 > "$ROOT/silent.out" 2>&1 &
silent_pid=$!
wait_for_run silent
wait "$silent_pid" || true
unset GUI_LOCK_TEST_LEASE_SECONDS
assert_contains "$ROOT/gui-lock.log" "lease expired while command ran lane=silent"
[ ! -d "$ROOT/.gui.lock" ] || fail "expired silent run retained its lease"

echo "test: reclaimed wrapper cannot kill the new holder"
reset_state
run_lane old pr 20 > "$ROOT/old.out" 2>&1 &
old_pid=$!
wait_for_run old
expire_current_lease
run_lane new pr 2 > "$ROOT/new.out" 2>&1 &
new_pid=$!
wait "$old_pid" || true
wait "$new_pid"
assert_contains "$ROOT/new.out" "RELEASED lane=new"

echo "test: interrupted guard owner is reclaimed"
reset_state
export GUI_LOCK_TEST_GUARD_HOLD_SECONDS=20
run_lane guard-victim pr 0 > "$ROOT/guard-victim.out" 2>&1 &
guard_victim_pid=$!
for attempt in $(seq 1 20); do
  [ -f "$ROOT/.gui.lock.guard/owner" ] && break
  sleep 1
done
[ -f "$ROOT/.gui.lock.guard/owner" ] || fail "guard victim never acquired the guard"
guard_owner_pid=$(sed -n 's/^pid=//p' "$ROOT/.gui.lock.guard/owner")
kill -9 "$guard_owner_pid" 2>/dev/null || true
wait "$guard_victim_pid" 2>/dev/null || true
unset GUI_LOCK_TEST_GUARD_HOLD_SECONDS
run_lane guard-reclaimer pr 0 > "$ROOT/guard-reclaimer.out"
assert_contains "$ROOT/guard-reclaimer.out" "RELEASED lane=guard-reclaimer"
assert_contains "$ROOT/gui-lock.log" "reclaimed guard"

echo "test: ownerless guard has a creation grace"
reset_state
mkdir "$ROOT/.gui.lock.guard"
run_lane ownerless-guard pr 0 > "$ROOT/ownerless-guard.out" 2>&1 &
ownerless_guard_pid=$!
sleep 2
[ -d "$ROOT/.gui.lock.guard" ] || fail "ownerless guard was reclaimed during creation grace"
if grep -F "reclaimed guard" "$ROOT/gui-lock.log" > /dev/null; then
  fail "fresh ownerless guard was stolen"
fi
wait "$ownerless_guard_pid"
assert_contains "$ROOT/gui-lock.log" "reclaimed guard pid=missing"

echo "test: a live guard owner is never stolen for age"
reset_state
export GUI_LOCK_TEST_GUARD_HOLD_SECONDS=12
run_lane slow-guard pr 0 > "$ROOT/slow-guard.out" 2>&1 &
slow_guard_pid=$!
for attempt in $(seq 1 20); do
  [ -f "$ROOT/.gui.lock.guard/owner" ] && break
  sleep 1
done
[ -f "$ROOT/.gui.lock.guard/owner" ] || fail "slow guard never published its owner"
unset GUI_LOCK_TEST_GUARD_HOLD_SECONDS
run_lane slow-guard-waiter pr 0 > "$ROOT/slow-guard-waiter.out" 2>&1 &
slow_guard_waiter_pid=$!
sleep 11
if grep -F "reclaimed guard" "$ROOT/gui-lock.log" > /dev/null; then
  fail "live slow guard was stolen after ten seconds"
fi
wait "$slow_guard_pid" "$slow_guard_waiter_pid"

echo "test: interrupted guard publication preserves the guard until grace"
reset_state
export GUI_LOCK_TEST_GUARD_PUBLISH_SECONDS=3
run_lane publishing-guard pr 0 > "$ROOT/publishing-guard.out" 2>&1 &
publishing_guard_pid=$!
for attempt in $(seq 1 20); do
  [ -d "$ROOT/.gui.lock.guard" ] && break
  sleep 1
done
unset GUI_LOCK_TEST_GUARD_PUBLISH_SECONDS
run_lane publishing-waiter pr 0 > "$ROOT/publishing-waiter.out" 2>&1 &
publishing_waiter_pid=$!
sleep 2
if grep -F "reclaimed guard" "$ROOT/gui-lock.log" > /dev/null; then
  fail "contender stole a guard before owner publication"
fi
wait "$publishing_guard_pid" "$publishing_waiter_pid"

echo "test: killed waiter ticket is reclaimed without losing live FIFO positions"
reset_state
run_lane ticket-holder pr 6 > "$ROOT/ticket-holder.out" 2>&1 &
ticket_holder_pid=$!
wait_for_run ticket-holder
run_lane abandoned-ticket pr 0 > "$ROOT/abandoned-ticket.out" 2>&1 &
abandoned_waiter_pid=$!
for attempt in $(seq 1 20); do
  ticket_file=$(find "$ROOT/.gui.queue/pr" -name '*-abandoned-ticket' -type d -print -quit)
  [ -n "$ticket_file" ] && [ -f "$ticket_file/ticket" ] && break
  sleep 1
done
[ -n "${ticket_file:-}" ] || fail "abandoned waiter did not enqueue"
ticket_owner_pid=$(sed -n 's/^owner_pid=//p' "$ticket_file/ticket")
[ -n "$ticket_owner_pid" ] || fail "ticket did not record its owner PID"
kill -9 "$ticket_owner_pid"
wait "$abandoned_waiter_pid" 2>/dev/null || true
run_lane next-ticket pr 0 > "$ROOT/next-ticket.out" 2>&1 &
next_ticket_pid=$!
wait "$ticket_holder_pid" "$next_ticket_pid"
assert_contains "$ROOT/gui-lock.log" "reclaimed ticket=$(basename "$ticket_file")"
assert_contains "$ROOT/next-ticket.out" "RELEASED lane=next-ticket"

echo "test: killed waiter before ticket metadata is published"
reset_state
mkdir "$ROOT/.gui.queue/pr/000000000001-owner999999-incomplete"
run_lane incomplete-reclaimer pr 0 > "$ROOT/incomplete.out"
assert_contains "$ROOT/gui-lock.log" "reclaimed ticket=000000000001-owner999999-incomplete"
assert_contains "$ROOT/incomplete.out" "RELEASED lane=incomplete-reclaimer"

echo "test: reused run directory keeps PID cleanup token-specific"
reset_state
shared_dir="$ROOT/run-reused"
run_lane_in_dir reused-old pr 20 "$shared_dir" > "$ROOT/reused-old.out" 2>&1 &
reused_old_pid=$!
wait_for_run reused-old
old_pids_file=$(sed -n 's/^pids_file=//p' "$ROOT/.gui.lock/owner")
expire_current_lease
run_lane_in_dir reused-new pr 10 "$shared_dir" > "$ROOT/reused-new.out" 2>&1 &
reused_new_pid=$!
wait_for_run reused-new
new_pids_file=$(sed -n 's/^pids_file=//p' "$ROOT/.gui.lock/owner")
[ "$old_pids_file" != "$new_pids_file" ] || fail "reused directory shared one PID file"
wait "$reused_old_pid" || true
wait "$reused_new_pid"
assert_contains "$ROOT/reused-new.out" "RELEASED lane=reused-new"

echo "test: stale release cannot rename a successor lease"
reset_state
export GUI_LOCK_TEST_RELEASE_PRE_GUARD_SECONDS=5
export GUI_LOCK_TEST_RELEASE_MARKER="$ROOT/release-entered"
run_lane release-old pr 0 > "$ROOT/release-old.out" 2>&1 &
release_old_pid=$!
for attempt in $(seq 1 20); do
  [ -f "$ROOT/release-entered" ] && break
  sleep 1
done
[ -f "$ROOT/release-entered" ] || fail "old release did not enter its race window"
expire_current_lease
unset GUI_LOCK_TEST_RELEASE_PRE_GUARD_SECONDS GUI_LOCK_TEST_RELEASE_MARKER
run_lane release-new pr 2 > "$ROOT/release-new.out" 2>&1 &
release_new_pid=$!
wait_for_run release-new
wait "$release_old_pid" || true
wait "$release_new_pid"
assert_contains "$ROOT/release-new.out" "RELEASED lane=release-new"

echo "test: renewing holder wins its waiter race"
reset_state
renew_dir="$ROOT/run-renew"
"$SCRIPT" run --lane renew --class pr --pr 1 --sha test --dir "$renew_dir" --lease-minutes 1 \
  --result "$renew_dir/result.xcresult" -- \
  bash -c 'for tick in 1 2 3; do echo heartbeat; sleep 1; done; mkdir -p "$1"; echo completed' _ \
    "$renew_dir/result.xcresult" > "$ROOT/renew.out" 2>&1 &
renew_pid=$!
wait_for_holder renew
run_lane renewal-waiter pr 0 > "$ROOT/renewal-waiter.out" 2>&1 &
waiter_pid=$!
wait "$renew_pid" "$waiter_pid"
if grep -F "reclaimed lane=renew" "$ROOT/gui-lock.log" > /dev/null; then
  fail "waiter reclaimed a renewing holder"
fi

echo "test: timeout wrapper requires immediate xcodebuild"
if (
  unset GUI_LOCK_TEST_MODE
  "$SCRIPT" run --lane invalid-timeout-shell --class pr --sha test --dir "$ROOT/invalid-timeout-shell" -- \
    timeout --kill-after=30 180 bash -lc 'xcodebuild test-without-building' xcodebuild test-without-building
) > /dev/null 2>&1; then
  fail "timeout accepted bash -lc before xcodebuild"
fi
if (
  unset GUI_LOCK_TEST_MODE
  "$SCRIPT" run --lane invalid-bash --class pr --sha test --dir "$ROOT/invalid-bash" -- \
    bash -c 'xcodebuild test-without-building'
) > /dev/null 2>&1; then
  fail "direct bash -c wrapper was accepted"
fi

echo "PASS: gui-lock lease tests"
