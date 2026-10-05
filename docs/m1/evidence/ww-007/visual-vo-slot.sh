#!/bin/sh
# WW-007 C04/C05 + VoiceOver slot. Mac mini only, under the coordinator GUI lock.
# Records originals, sets temporary settings, runs tests, ALWAYS restores (trap), verifies by re-reading.
cd "$(dirname "$0")"
U=com.apple.universalaccess
LOG=slot.log
X=Products/WaveWranglerUITests_macosx27.0-arm64.xctestrun
T=WaveWranglerUITests
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a $LOG; }
snapshot() { # $1 = label
  log "== snapshot $1"
  for k in increaseContrast reduceMotion reduceTransparency FontSizeCategory; do
    v=$(defaults read $U $k 2>/dev/null | tr '\n' ' ' || true); t=$(defaults read-type $U $k 2>/dev/null || echo absent)
    log "$U $k = ${v:-<absent>} ($t)"
  done
  for d in com.apple.VoiceOver4/default com.apple.VoiceOverTraining; do
    defaults read $d >/dev/null 2>&1 && log "$d present" || log "$d absent"
  done
  log "VoiceOver processes: $(pgrep -x VoiceOver | tr '\n' ' ')"
  log "probe: $(./a11yprobe)"
}
restore_visual() {
  log "restore visual"
  defaults write $U increaseContrast -bool false
  defaults delete $U reduceMotion 2>/dev/null
  defaults delete $U FontSizeCategory 2>/dev/null
}
restore_vo() {
  log "restore VoiceOver"
  for p in $(pgrep -x VoiceOver); do log "kill VoiceOver pid $p"; kill $p; done
  sleep 3
  defaults delete com.apple.VoiceOverTraining 2>/dev/null
  defaults delete com.apple.VoiceOver4/default 2>/dev/null
}
cleanup() { restore_visual; restore_vo; sleep 2; snapshot after-restore; log "SLOT DONE"; }
trap cleanup EXIT INT TERM

snapshot originals
# 0. C03/C07 re-measurement on the current head with system settings at their originals (in-app overrides only).
xcodebuild test-without-building -xctestrun $X -destination platform=macOS,arch=arm64 -parallel-testing-enabled NO \
  -resultBundlePath runR.xcresult -only-testing:$T/ContrastEvidenceUITests/testVisualOverridesLightDarkReduceMotion200 \
  -only-testing:$T/ContrastEvidenceUITests/testSaturationZeroShowWindow -only-testing:$T/ContrastEvidenceUITests/testTextSize200Screenshots > runR.log 2>&1
log "re-measurement tests exit $?"
# 1. Visual (grant D): Increase Contrast, Reduce Motion, larger text.
log "set visual"
defaults write $U increaseContrast -bool true 2>&1 | tee -a $LOG
defaults write $U reduceMotion -bool true 2>&1 | tee -a $LOG
defaults write $U FontSizeCategory -dict global XXXL 2>&1 | tee -a $LOG
sleep 3
snapshot visual-on
TEST_RUNNER_WW_EXPECT_SYSTEM_VISUAL=on xcodebuild test-without-building -xctestrun $X -destination platform=macOS,arch=arm64 \
  -parallel-testing-enabled NO -resultBundlePath runV.xcresult -only-testing:$T/ContrastEvidenceUITests/testSystemVisualSettings > runV.log 2>&1
log "visual tests exit $?"
restore_visual; sleep 3; snapshot visual-restored

# 2. VoiceOver (grant B): on, walk, off.
log "start VoiceOver"
defaults write com.apple.VoiceOverTraining doNotShowSplashScreen -bool true
open -a /System/Library/CoreServices/VoiceOver.app 2>&1 | tee -a $LOG
sleep 8
snapshot vo-on
xcodebuild test-without-building -xctestrun $X -destination platform=macOS,arch=arm64 -parallel-testing-enabled NO \
  -resultBundlePath runVO.xcresult -only-testing:$T/VoiceOverWalkUITests > runVO.log 2>&1
log "VoiceOver tests exit $?"
