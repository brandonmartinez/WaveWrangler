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
run_lane holder pr 5 > "$ROOT/holder.out" 2>&1 &
holder_pid=$!
sleep 1
run_lane first-pr pr 0 > "$ROOT/first-pr.out" 2>&1 &
first_pr_pid=$!
sleep 1
run_lane perf perf 0 > "$ROOT/perf.out" 2>&1 &
perf_pid=$!
sleep 1
run_lane full full 0 > "$ROOT/full.out" 2>&1 &
full_pid=$!
run_lane required required 0 > "$ROOT/required.out" 2>&1 &
required_pid=$!
run_lane second-pr pr 0 > "$ROOT/second-pr.out" 2>&1 &
second_pr_pid=$!
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
sleep 1
"$SCRIPT" status > "$ROOT/status.out"
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
kill "$acquiring_waiter_pid" 2>/dev/null || true
wait "$acquiring_waiter_pid" 2>/dev/null || true

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
kill -9 "$guard_victim_pid" 2>/dev/null || true
wait "$guard_victim_pid" 2>/dev/null || true
rm -rf "$ROOT/.gui.queue/pr/"*guard-victim
unset GUI_LOCK_TEST_GUARD_HOLD_SECONDS
run_lane guard-reclaimer pr 0 > "$ROOT/guard-reclaimer.out"
assert_contains "$ROOT/guard-reclaimer.out" "RELEASED lane=guard-reclaimer"
assert_contains "$ROOT/gui-lock.log" "reclaimed guard"

echo "test: reused run directory keeps PID cleanup token-specific"
reset_state
shared_dir="$ROOT/run-reused"
run_lane_in_dir reused-old pr 20 "$shared_dir" > "$ROOT/reused-old.out" 2>&1 &
reused_old_pid=$!
wait_for_run reused-old
old_pids_file=$(sed -n 's/^pids_file=//p' "$ROOT/.gui.lock/owner")
expire_current_lease
run_lane_in_dir reused-new pr 2 "$shared_dir" > "$ROOT/reused-new.out" 2>&1 &
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
