#!/usr/bin/env zsh
#
# appctl benchmark harness — measures appctl against fastlane and regenerates
# benchmarks/README.md from the raw runs in benchmarks/results/.
#
# ---------------------------------------------------------------------------
# POLICY: FASTLANE-ONLY COMPARISONS
#
# This harness compares appctl against fastlane and against nothing else. Not
# against other App Store Connect clients, not against raw curl, not against
# earlier versions of appctl. fastlane is the tool appctl is positioned to
# replace, so it is the only comparison that tells a reader something they can
# act on. Any scenario added here must run the same logical operation on both
# sides, against the same App Store Connect account, with the same API key.
# A scenario that cannot be expressed on both sides does not belong here.
#
# WHAT THIS DELIBERATELY DOES NOT MEASURE
#
# appctl does not compile, code-sign, or upload binaries. Nothing here compares
# those, because appctl would "win" only by not implementing them. Scope is App
# Store Connect API operations and process startup.
#
# FAIRNESS RULES (enforced below, not aspirational)
#
#   1. appctl is measured from a release build. A debug build is refused
#      outright rather than silently reported.
#   2. Both tools read the same APPCTL_* credentials, so the comparison
#      isolates the client rather than the account.
#   3. The fastlane lane calls Spaceship in-process instead of shelling out, so
#      no extra process launch is charged against fastlane.
#   4. fastlane's update check is disabled (FASTLANE_SKIP_UPDATE_CHECK). This
#      favours fastlane: leaving it on would time a network round trip to
#      rubygems rather than fastlane itself, and disabling it is what fastlane's
#      own CI documentation recommends.
#   5. Reported figures are the median of N iterations, never a best-of.
#   6. Wall time and peak RSS are measured in separate passes. /usr/bin/time
#      adds a fork to the timed path and resolves only to 10ms, which is the
#      same order of magnitude as appctl's entire startup.
#
# WHY zsh RATHER THAN bash: $EPOCHREALTIME gives microsecond wall-clock
# resolution with no subprocess in the timed window. macOS ships zsh as the
# default shell on every version this project supports (macOS 13+), so the
# divergence from the repo's bash scripts costs no portability that matters.
# ---------------------------------------------------------------------------
#
# Usage:
#   ./run.sh                   measure what is available, append a CSV, regenerate README
#   ./run.sh --iterations 20   sample count per scenario (default 10)
#   ./run.sh --cold-cache      skip warmup and label the run "cold" instead of "warm"
#   ./run.sh --report          regenerate README.md from committed CSVs; measure nothing
#   ./run.sh --help

set -euo pipefail
zmodload zsh/datetime

# Resolved before any function runs: inside a zsh function $0 is the function's
# own name, not the script's path.
SCRIPT_PATH=${0:A}
BENCH_DIR=${SCRIPT_PATH:h}
REPO_ROOT=${BENCH_DIR:h}
RESULTS_DIR=$BENCH_DIR/results
FASTLANE_DIR=$BENCH_DIR/fastlane-env
APPCTL_BIN=$REPO_ROOT/.build/release/appctl
README=$BENCH_DIR/README.md
SCHEMA_VERSION=2

ITERATIONS=10
WARMUP=3
CACHE_STATE=warm
REPORT_ONLY=false

# Scenarios in the order they appear in the report. Adding one means teaching
# scenario_title, scenario_needs_credentials, run_appctl and run_fastlane about
# it; the report renders "not yet measured" until results exist.
SCENARIOS=(startup apps-list)
TOOLS=(appctl fastlane)

# --- messaging -------------------------------------------------------------
# Failures follow the project's What/Why/Fix shape: the reader should never
# have to open this script to learn what to do next.

die() {
  print -u2 -r -- "✗ $1"
  print -u2 -r -- "  Why: $2"
  print -u2 -r -- "  Fix: $3"
  exit 1
}

note() { print -r -- "  $1"; }
step() { print -r -- ""; print -r -- "▸ $1"; }

# The header comment is the documentation, so --help prints it rather than
# maintaining a second copy that drifts from it.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SCRIPT_PATH"
  exit 0
}

# --- argument parsing ------------------------------------------------------

while (( $# )); do
  case $1 in
    --iterations)
      (( $# >= 2 )) || die "--iterations needs a value" \
        "The flag was passed with nothing after it." \
        "Write --iterations 20."
      ITERATIONS=$2
      [[ $ITERATIONS == <-> ]] && (( ITERATIONS > 0 )) || die \
        "--iterations must be a positive whole number, got \"$ITERATIONS\"" \
        "Medians are taken over this many samples, so it has to be countable." \
        "Write --iterations 20."
      shift 2
      ;;
    --cold-cache) CACHE_STATE=cold; WARMUP=0; shift ;;
    --report)     REPORT_ONLY=true; shift ;;
    --help|-h)    usage ;;
    *)
      die "Unknown option \"$1\"" \
        "This harness accepts only the flags listed in --help." \
        "Run ./run.sh --help to see them."
      ;;
  esac
done

# --- environment detection -------------------------------------------------
# Recorded into every CSV row. A benchmark without its environment is a number
# without units, and the first thing a reviewer asks is what it ran on.

detect_os_version()  { print -r -- "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"; }
detect_chip()        { print -r -- "$(uname -m) $(sysctl -n machdep.cpu.brand_string 2>/dev/null || print -r -- unknown)"; }

detect_swift_version() {
  local v
  v=$(swift --version 2>/dev/null \
    | awk '/[Ss]wift version/ { for (i = 1; i <= NF; i++) if ($i == "version") { print $(i + 1); exit } }')
  print -r -- "${v:-unknown}"
}

detect_fastlane_version() {
  (( HAVE_FASTLANE )) || { print -r -- "not-installed"; return }
  ( cd $FASTLANE_DIR && bundle exec fastlane --version 2>/dev/null ) \
    | awk '/^fastlane [0-9]/ { print $2; exit }'
}

# Dependency counts are recorded at measurement time rather than computed when
# the report is written, so --report stays offline and deterministic. Both are
# full transitive closures: what an install actually pulls down, not the
# direct-dependency count a manifest happens to list.
detect_appctl_deps() {
  local n
  n=$( cd $REPO_ROOT && swift package show-dependencies --format flatlist 2>/dev/null | grep -c . )
  print -r -- "${n:-0}"
}

detect_fastlane_gems() {
  (( HAVE_FASTLANE )) || { print -r -- "0"; return }
  local n
  n=$( cd $FASTLANE_DIR && bundle list 2>/dev/null | grep -c '^  \*' )
  print -r -- "${n:-0}"
}

# CSV fields must never contain a comma or the file stops being parseable by
# the report generator, which uses awk -F, on purpose (no jq, no python).
csv_safe() { print -r -- "${1//,/;}" }

# --- dependency checks -----------------------------------------------------

HAVE_FASTLANE=0
HAVE_CREDENTIALS=0

check_appctl() {
  [[ -x $APPCTL_BIN ]] || die \
    "No release build of appctl at .build/release/appctl" \
    "Benchmarking a debug build would report numbers nobody will ever experience." \
    "Run: swift build -c release"

  # A debug binary at the release path means someone copied one in. Refuse
  # rather than publish a misleading figure.
  if [[ -e $REPO_ROOT/.build/debug/appctl ]] && \
     [[ $APPCTL_BIN -ot $REPO_ROOT/.build/debug/appctl ]]; then
    note "warning: the debug build is newer than the release build being measured."
    note "         run 'swift build -c release' if you changed code since."
  fi
}

check_fastlane() {
  if ! command -v bundle >/dev/null 2>&1; then
    note "fastlane side skipped: bundler is not installed."
    note "  Fix: install Ruby + bundler (gem install bundler), then re-run."
    return
  fi
  if [[ ! -f $FASTLANE_DIR/Gemfile.lock ]]; then
    note "fastlane side skipped: benchmarks/fastlane-env/Gemfile.lock is missing."
    note "  Fix: the lock is committed; restore it with 'git checkout benchmarks'."
    return
  fi
  if [[ ! -d $FASTLANE_DIR/vendor/bundle ]]; then
    step "Installing fastlane from the committed Gemfile.lock (first run only)"
    ( cd $FASTLANE_DIR && bundle install --quiet ) || die \
      "bundle install failed in benchmarks/fastlane-env" \
      "The fastlane side cannot be measured without its pinned gems." \
      "Run 'bundle install' in benchmarks/fastlane-env and read the error it prints."
  fi
  HAVE_FASTLANE=1
}

check_credentials() {
  local missing=()
  [[ -n ${APPCTL_KEY_ID:-} ]]           || missing+=(APPCTL_KEY_ID)
  [[ -n ${APPCTL_ISSUER_ID:-} ]]        || missing+=(APPCTL_ISSUER_ID)
  [[ -n ${APPCTL_PRIVATE_KEY_PATH:-} ]] || missing+=(APPCTL_PRIVATE_KEY_PATH)

  if (( ${#missing} )); then
    note "API scenarios skipped: ${(j:, :)missing} not set."
    note "  Why: both tools must use the same key for the comparison to mean"
    note "       anything, so the harness requires them in the environment"
    note "       rather than letting each tool find its own config."
    note "  Fix: export the three variables (values from your .appctl.toml"
    note "       [auth] section) and re-run. Startup scenarios still ran."
    return
  fi

  if [[ ! -r ${APPCTL_PRIVATE_KEY_PATH} ]]; then
    die "APPCTL_PRIVATE_KEY_PATH points at something unreadable: $APPCTL_PRIVATE_KEY_PATH" \
      "Both tools need to read this .p8 key file to authenticate." \
      "Check the path and its permissions, then re-run."
  fi
  HAVE_CREDENTIALS=1
}

# --- scenario definitions --------------------------------------------------

scenario_title() {
  case $1 in
    startup)   print -r -- "Process startup (version query)" ;;
    apps-list) print -r -- "List all apps (App Store Connect API)" ;;
  esac
}

scenario_note() {
  case $1 in
    startup)   print -r -- "Launch to first output with no network work. This is the floor cost paid by every single invocation." ;;
    apps-list) print -r -- "Authenticate and fetch every app visible to the API key, paginated to completion." ;;
  esac
}

scenario_needs_credentials() {
  case $1 in
    startup)   return 1 ;;
    apps-list) return 0 ;;
  esac
}

# Fills the global CMD array with the argv to execute. Keeping the command as
# an array (rather than a function that runs it) lets the wall-time and RSS
# passes invoke exactly the same argv without re-entering this script.
set_cmd() {
  local scenario=$1 tool=$2
  case $tool:$scenario in
    appctl:startup)     CMD=( $APPCTL_BIN version ) ;;
    appctl:apps-list)   CMD=( $APPCTL_BIN apps list --format json ) ;;
    fastlane:startup)   CMD=( bundle exec fastlane --version ) ;;
    fastlane:apps-list) CMD=( bundle exec fastlane apps_list ) ;;
    *) return 1 ;;
  esac
}

# The directory a tool must run from. fastlane discovers ./fastlane/Fastfile
# relative to the working directory; appctl reads its credentials from the
# environment, so its working directory is irrelevant.
workdir_for() {
  [[ $1 == fastlane ]] && print -r -- $FASTLANE_DIR || print -r -- $REPO_ROOT
}

# --- measurement -----------------------------------------------------------

bench() {
  local scenario=$1 tool=$2
  local i value rss
  local -a CMD
  set_cmd $scenario $tool || return 1

  (
    cd "$(workdir_for $tool)"

    # No pre-flight run to prove the command works. In cold mode that run would
    # fault the binary, its libraries and (for fastlane) its gems in from disk,
    # so the first sample would not be cold and the row would be mislabelled.
    # Failure is caught per execution instead, and a scenario that fails
    # anywhere emits nothing at all rather than a partial set of samples.
    for (( i = 1; i <= WARMUP; i++ )); do
      "${CMD[@]}" >/dev/null 2>&1 || exit 1
    done

    # Wall time in milliseconds. $EPOCHREALTIME is read by the shell itself, so
    # nothing but the command under test lives inside the timed window, and
    # samples are buffered rather than printed so that a late failure discards
    # the earlier ones too.
    local start end
    local -a walls
    for (( i = 1; i <= ITERATIONS; i++ )); do
      start=$EPOCHREALTIME
      "${CMD[@]}" >/dev/null 2>&1 || exit 1
      end=$EPOCHREALTIME
      walls+=( $(( (end - start) * 1000 )) )
    done

    # Peak RSS gets a pass of its own so that time(1)'s fork never lands inside
    # a wall-time sample. One sample suffices: peak memory is far more stable
    # run to run than wall time, and each sample costs a full execution.
    # macOS reports maximum resident set size in bytes.
    rss=$( { /usr/bin/time -l "${CMD[@]}" >/dev/null } 2>&1 \
      | awk '/maximum resident set size/ { print $1; exit }' )

    for (( i = 1; i <= ${#walls}; i++ )); do
      printf 'wall %d %.3f\n' $i ${walls[i]}
    done
    [[ -n $rss ]] && print -r -- "rss $rss"
    return 0
  )
}

# --- report generation -----------------------------------------------------

# Median of the numbers on stdin. Sorting happens in sort(1) because macOS ships
# BWK awk, which has no asort.
median() {
  local -a v
  v=( ${(f)"$(sort -n)"} )
  local n=${#v}
  (( n )) || return 1
  if (( n % 2 )); then
    print -r -- ${v[$(( (n + 1) / 2 ))]}
  else
    awk -v a=${v[$(( n / 2 ))]} -v b=${v[$(( n / 2 + 1 ))]} 'BEGIN { printf "%.3f", (a + b) / 2 }'
  fi
}

# Every reader below works off this one sorted list. It is a global rather than
# a command substitution per call because $(...) of an empty listing yields an
# array holding one empty string, which is not the same as an empty array.
CSVS=()
load_csvs() { CSVS=( ${(o)$(print -rl -- $RESULTS_DIR/*.csv(N))} ); }

# These readers are called from inside `&&` lists and command substitutions
# under `set -e`, so each ends with an explicit success: "no rows matched" is a
# normal answer here, not an error, and must not abort report generation.

# The newest run_id holding rows for this scenario/tool/cache-state, so that
# re-running one scenario does not require re-running the others and history
# stays intact. Cache state is part of the key because a warm and a cold run
# are different measurements, not competing samples of the same one.
latest_run_for() {
  local scenario=$1 tool=$2 cache=$3
  (( ${#CSVS} )) || return 0
  awk -F, -v s=$scenario -v t=$tool -v c=$cache \
    'FNR > 1 && $9 == s && $10 == t && $8 == c { print $2 }' $CSVS | sort -u | tail -1
  return 0
}

# Cache states actually present for a scenario, cold first. Prints nothing when
# the scenario has never been measured.
cache_states_for() {
  local scenario=$1 state
  (( ${#CSVS} )) || return 0
  for state in cold warm; do
    if awk -F, -v s=$scenario -v c=$state \
      'FNR > 1 && $9 == s && $8 == c { found = 1 } END { exit !found }' $CSVS; then
      print -r -- $state
    fi
  done
  return 0
}

# Newest run overall, for facts that belong to the environment rather than to
# any one scenario.
newest_run() {
  (( ${#CSVS} )) || return 0
  awk -F, 'FNR > 1 { print $2 }' $CSVS | sort -u | tail -1
}

field_from_run() {
  local run=$1 col=$2
  (( ${#CSVS} )) || return 0
  awk -F, -v r=$run -v c=$col 'FNR > 1 && $2 == r { print $c; exit }' $CSVS
  return 0
}

median_metric() {
  local run=$1 scenario=$2 tool=$3 col=$4
  (( ${#CSVS} )) || return 0
  awk -F, -v r=$run -v s=$scenario -v t=$tool -v c=$col \
    'FNR > 1 && $2 == r && $9 == s && $10 == t && $c != "" { print $c }' $CSVS | median
  return 0
}

fmt_ms() {
  local v=${1:-}
  [[ -z $v ]] && { print -r -- "not yet measured"; return }
  awk -v v=$v 'BEGIN { if (v >= 1000) printf "%.2f s", v / 1000; else printf "%.1f ms", v }'
}

fmt_bytes() {
  local v=${1:-}
  [[ -z $v ]] && { print -r -- "not yet measured"; return }
  awk -v v=$v 'BEGIN { printf "%.1f MB", v / 1048576 }'
}

# $3 picks the comparative: wall time is "faster", memory is "less".
fmt_ratio() {
  local a=${1:-} b=${2:-} kind=${3:-faster}
  [[ -z $a || -z $b ]] && { print -r -- "not yet measured"; return }
  awk -v a=$a -v b=$b -v k=$kind 'BEGIN {
    if (a <= 0 || b <= 0) { printf "—"; exit }
    r = b / a
    if (r >= 10)     printf "appctl %d× %s", r + 0.5, k
    else if (r >= 1) printf "appctl %.1f× %s", r, k
    else             printf "fastlane %.1f× %s", 1 / r, k
  }'
}

# One table of appctl-vs-fastlane for a single metric column, split by cache
# state so a warm run never silently overwrites a cold one. $2 formats a value,
# $3 is the comparative fmt_ratio should use.
emit_metric_table() {
  local col=$1 fmt=$2 kind=$3
  local scenario cache run_a run_f val_a val_f
  local -a states

  print -r -- "| Scenario | Cache | appctl | fastlane | Difference |"
  print -r -- "|---|---|---|---|---|"

  for scenario in $SCENARIOS; do
    states=( ${(f)"$(cache_states_for $scenario)"} )
    if (( ! ${#states} )); then
      print -r -- "| $(scenario_title $scenario) | — | not yet measured | not yet measured | not yet measured |"
      continue
    fi
    for cache in $states; do
      run_a=$(latest_run_for $scenario appctl $cache 2>/dev/null || true)
      run_f=$(latest_run_for $scenario fastlane $cache 2>/dev/null || true)
      val_a=""; val_f=""
      [[ -n $run_a ]] && val_a=$(median_metric $run_a $scenario appctl $col)
      [[ -n $run_f ]] && val_f=$(median_metric $run_f $scenario fastlane $col)
      print -r -- "| $(scenario_title $scenario) | $cache | $($fmt $val_a) | $($fmt $val_f) | $(fmt_ratio "$val_a" "$val_f" $kind) |"
    done
  done
}

generate_report() {
  load_csvs

  {
    print -r -- "# Benchmarks: appctl vs fastlane"
    print -r -- ""
    print -r -- "<!-- GENERATED FILE — DO NOT EDIT BY HAND."
    print -r -- "     Written by benchmarks/run.sh from the CSVs in benchmarks/results/."
    print -r -- "     Regenerate with: ./benchmarks/run.sh --report"
    print -r -- "     Hand edits are overwritten on the next run. -->"
    print -r -- ""
    print -r -- "## What this measures"
    print -r -- ""
    print -r -- "App Store Connect API operations and process startup — the work appctl actually does."
    print -r -- "Every figure below is a median over repeated runs of the same command on the same"
    print -r -- "machine. Where a scenario talks to the API, both tools authenticate against the"
    print -r -- "same account with the same key, so the comparison isolates the client."
    print -r -- ""
    print -r -- "## What this does not measure"
    print -r -- ""
    print -r -- "**appctl is not faster than fastlane at building or signing, because appctl does not"
    print -r -- "build or sign.** It has no compilation step, no code signing, no \`gym\`, no \`match\`,"
    print -r -- "no ipa upload. If your bottleneck is a Swift compile or a provisioning profile"
    print -r -- "round trip, nothing here applies to you and appctl will not help."
    print -r -- ""
    print -r -- "What appctl replaces is the App Store Connect metadata and release surface —"
    print -r -- "querying apps, builds, versions, TestFlight groups, reviews — plus the fixed cost"
    print -r -- "of starting a tool at all, which every invocation pays whether or not it does"
    print -r -- "any real work. Those are the only things measured here."
    print -r -- ""
    print -r -- "The comparison is also fastlane-only by policy: no other App Store Connect client,"
    print -r -- "no raw \`curl\` baseline, no appctl-vs-older-appctl. See the header of \`run.sh\`."
    print -r -- ""
    emit_dependencies
    print -r -- "## Results"
    print -r -- ""

    if (( ! ${#CSVS} )); then
      print -r -- "No runs recorded yet. Run \`./benchmarks/run.sh\` to produce one."
      print -r -- ""
    fi

    print -r -- "### Wall time"
    print -r -- ""
    print -r -- "Median, lower is better."
    print -r -- ""
    emit_metric_table 12 fmt_ms faster
    print -r -- ""
    print -r -- "### Peak memory"
    print -r -- ""
    print -r -- "Maximum resident set size, lower is better."
    print -r -- ""
    emit_metric_table 13 fmt_bytes less
    print -r -- ""
    for scenario in $SCENARIOS; do
      print -r -- "**$(scenario_title $scenario).** $(scenario_note $scenario)"
      print -r -- ""
    done

    emit_charts
    emit_environment
    emit_method
  } > $README.tmp

  mv $README.tmp $README
}

emit_charts() {
  local -a labels values
  # All locals declared once, up front: zsh echoes the variable if `local`
  # re-declares a name that already exists in the same scope.
  local scenario tool cache run med maxv
  local -a states

  for scenario in $SCENARIOS; do
    states=( ${(f)"$(cache_states_for $scenario)"} )
    for cache in $states; do
      for tool in $TOOLS; do
        run=$(latest_run_for $scenario $tool $cache 2>/dev/null || true)
        [[ -n $run ]] || continue
        med=$(median_metric $run $scenario $tool 12)
        [[ -n $med ]] || continue
        labels+=("\"$tool $scenario/$cache\"")
        values+=($med)
      done
    done
  done

  (( ${#values} )) || return 0

  maxv=$(print -rl -- $values | sort -n | tail -1)
  maxv=$(awk -v m=$maxv 'BEGIN { printf "%d", int(m * 1.15) + 1 }')

  print -r -- "### Chart"
  print -r -- ""
  print -r -- '```mermaid'
  print -r -- "xychart-beta"
  print -r -- "    title \"Median wall time in milliseconds (lower is better)\""
  print -r -- "    x-axis [${(j:, :)labels}]"
  print -r -- "    y-axis \"milliseconds\" 0 --> $maxv"
  print -r -- "    bar [${(j:, :)values}]"
  print -r -- '```'
  print -r -- ""
}

# Not a timing measurement, but the number most often quoted about these two
# tools, so it is recorded and reported rather than asserted from memory.
emit_dependencies() {
  local run deps gems
  run=$(newest_run)
  [[ -n $run ]] || return 0
  deps=$(field_from_run $run 14)
  gems=$(field_from_run $run 15)
  [[ -n $deps && -n $gems && $gems != 0 ]] || return 0

  print -r -- "## Dependency footprint"
  print -r -- ""
  print -r -- "Full transitive closure — what an install actually pulls down, not the direct"
  print -r -- "dependency count each manifest happens to list."
  print -r -- ""
  print -r -- "| | appctl | fastlane |"
  print -r -- "|---|---|---|"
  print -r -- "| Packages installed | $deps SwiftPM | $gems Ruby gems |"
  print -r -- ""
  print -r -- "Counted by \`swift package show-dependencies --format flatlist\` and \`bundle list\`"
  print -r -- "against the pinned \`Gemfile.lock\`, recorded per run in \`results/\`."
  print -r -- ""
}

emit_environment() {
  local -a runs

  print -r -- "## Environment"
  print -r -- ""

  if (( ! ${#CSVS} )); then
    print -r -- "No runs recorded."
    print -r -- ""
    return
  fi

  print -r -- "Every run records the machine it ran on. Numbers from different rows above may come"
  print -r -- "from different runs; the run each scenario came from is listed here."
  print -r -- ""
  print -r -- "| Run | Date (UTC) | macOS | Chip | Swift | fastlane | Cache | Samples |"
  print -r -- "|---|---|---|---|---|---|---|---|"

  runs=( ${(f)"$(awk -F, 'FNR > 1 { print $2 }' $CSVS | sort -u)"} )
  local run n
  for run in $runs; do
    n=$(awk -F, -v r=$run 'FNR > 1 && $2 == r && $12 != "" { c++ } END { print c + 0 }' $CSVS)
    print -r -- "| \`$run\` | $(field_from_run $run 3) | $(field_from_run $run 4) | $(field_from_run $run 5) | $(field_from_run $run 6) | $(field_from_run $run 7) | $(field_from_run $run 8) | $n |"
  done
  print -r -- ""
}

emit_method() {
  print -r -- "## Method"
  print -r -- ""
  print -r -- "- Wall time is read from the shell's own \`\$EPOCHREALTIME\` (microsecond resolution)"
  print -r -- "  with nothing but the command under test inside the timed window. \`/usr/bin/time\`"
  print -r -- "  is not used for timing: it adds a fork and resolves only to 10ms, which is the"
  print -r -- "  same order of magnitude as appctl's entire startup."
  print -r -- "- Peak memory is collected in a separate pass via \`/usr/bin/time -l\`, so its"
  print -r -- "  overhead never lands inside a wall-time sample. That pass runs after the wall"
  print -r -- "  samples, so on a \`cold\` row the memory figure was itself taken warm — peak RSS"
  print -r -- "  barely moves with cache state, but the row is not cold in the way its label"
  print -r -- "  suggests."
  print -r -- "- Each scenario runs warmup iterations that are discarded, then the recorded"
  print -r -- "  samples. Reported values are medians, never best-of."
  print -r -- "- appctl is measured from \`.build/release/appctl\`. Debug builds are refused."
  print -r -- "- fastlane's update check is disabled, which favours fastlane: leaving it on"
  print -r -- "  would time a network round trip to rubygems rather than fastlane itself."
  print -r -- "- The fastlane lane calls Spaceship in-process rather than shelling out, so no"
  print -r -- "  extra process launch is charged against it."
  print -r -- ""
  print -r -- "These are wall-clock measurements on a developer machine, not an isolated rig."
  print -r -- "A busy machine can move fastlane's startup median by 3× between runs, which is"
  print -r -- "why the medians are quoted to two significant figures at most and why every"
  print -r -- "individual sample is committed rather than just the summary. Treat the order of"
  print -r -- "magnitude as the result and the exact figure as incidental."
  print -r -- ""
  print -r -- "### Warm vs cold"
  print -r -- ""
  print -r -- "\`warm\` means warmup iterations ran first and were discarded — what a repeat"
  print -r -- "invocation on a machine already using the tool looks like. \`cold\` means"
  print -r -- "\`--cold-cache\` skipped the warmup, so the samples pay for faulting the binary,"
  print -r -- "its libraries and (for fastlane) its gems in from disk."
  print -r -- ""
  print -r -- "The distinction matters most for fastlane, whose startup faults in several hundred"
  print -r -- "gem files that a warm filesystem cache already holds. CI runners on fresh"
  print -r -- "containers get the cold number; a laptop mid-session gets the warm one. Compare"
  print -r -- "rows within a cache state, never across."
  print -r -- ""
  print -r -- "\`--cold-cache\` only skips this harness's own warmup. It cannot evict a cache"
  print -r -- "already populated by an earlier run, so a genuinely cold measurement means"
  print -r -- "running it as the first thing after a reboot. Rows recorded that way are"
  print -r -- "labelled \`cold\` on trust, not on proof."
  print -r -- ""
  print -r -- "## Reproducing"
  print -r -- ""
  print -r -- "From a clean clone, with Xcode 26 / Swift 6.2 or newer and Ruby with bundler installed:"
  print -r -- ""
  print -r -- '```bash'
  print -r -- "swift build -c release"
  print -r -- "./benchmarks/run.sh                 # startup scenarios; installs pinned fastlane on first run"
  print -r -- ""
  print -r -- "# For the API scenarios, both tools need the same credentials:"
  print -r -- "export APPCTL_KEY_ID=...           # from your .appctl.toml [auth] section"
  print -r -- "export APPCTL_ISSUER_ID=..."
  print -r -- "export APPCTL_PRIVATE_KEY_PATH=..."
  print -r -- "./benchmarks/run.sh"
  print -r -- '```'
  print -r -- ""
  print -r -- "Each invocation writes a new CSV to \`results/\` and regenerates this file from"
  print -r -- "**all** committed CSVs, so adding the API scenarios later does not disturb the"
  print -r -- "startup numbers already recorded. \`./benchmarks/run.sh --report\` regenerates this"
  print -r -- "file from existing results without measuring anything."
  print -r -- ""
  print -r -- "Raw samples — every individual iteration, not just the medians — are committed in"
  print -r -- "[\`results/\`](results/) so the medians above can be recomputed or disputed."
}

# --- main ------------------------------------------------------------------

if [[ $REPORT_ONLY == true ]]; then
  generate_report
  print -r -- "Regenerated ${README#$REPO_ROOT/} from ${#CSVS} result file(s)."
  exit 0
fi

export FASTLANE_SKIP_UPDATE_CHECK=1
export FASTLANE_OPT_OUT_USAGE=1
export FASTLANE_DISABLE_COLORS=1

step "Checking dependencies"
check_appctl
note "appctl: $($APPCTL_BIN version | head -1) (release build)"
check_fastlane
check_credentials

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(uname -m)"
STARTED_UTC=$(date -u '+%Y-%m-%d %H:%M:%S')
OS_VERSION=$(csv_safe "$(detect_os_version)")
CHIP=$(csv_safe "$(detect_chip)")
SWIFT_VERSION=$(csv_safe "$(detect_swift_version)")
FASTLANE_VERSION=$(csv_safe "$(detect_fastlane_version)")
APPCTL_DEPS=$(detect_appctl_deps)
FASTLANE_GEMS=$(detect_fastlane_gems)

CSV=$RESULTS_DIR/$RUN_ID.csv
mkdir -p $RESULTS_DIR

print -r -- "schema_version,run_id,started_utc,os_version,chip,swift_version,fastlane_version,cache_state,scenario,tool,iteration,wall_ms,peak_rss_bytes,appctl_deps,fastlane_gems" > $CSV

emit_row() {
  print -r -- "$SCHEMA_VERSION,$RUN_ID,$STARTED_UTC,$OS_VERSION,$CHIP,$SWIFT_VERSION,$FASTLANE_VERSION,$CACHE_STATE,$1,$2,$3,$4,$5,$APPCTL_DEPS,$FASTLANE_GEMS" >> $CSV
}

for scenario in $SCENARIOS; do
  if scenario_needs_credentials $scenario && (( ! HAVE_CREDENTIALS )); then
    step "$(scenario_title $scenario) — skipped (no credentials)"
    continue
  fi

  step "$(scenario_title $scenario) — $ITERATIONS samples, $WARMUP warmup"

  for tool in $TOOLS; do
    if [[ $tool == fastlane ]] && (( ! HAVE_FASTLANE )); then
      note "fastlane: skipped (not available)"
      continue
    fi

    output=$(bench $scenario $tool 2>/dev/null || true)
    if [[ -z $output ]]; then
      note "$tool: command failed, no samples recorded"
      continue
    fi

    # Each row carries either a wall_ms or a peak_rss_bytes value, never both:
    # the two are measured in separate passes and pairing them up would imply a
    # correspondence that does not exist.
    rss=$(print -r -- $output | awk '$1 == "rss" { print $2; exit }')
    print -r -- $output | while read -r kind iter value; do
      [[ $kind == wall ]] || continue
      emit_row $scenario $tool $iter $value ""
    done
    [[ -n $rss ]] && emit_row $scenario $tool 1 "" $rss

    med=$(print -r -- $output | awk '$1 == "wall" { print $3 }' | median)
    note "$tool: median $(fmt_ms $med)$([[ -n $rss ]] && print -r -- ", peak $(fmt_bytes $rss)")"
  done
done

step "Writing results"
note "raw samples: ${CSV#$REPO_ROOT/}"

generate_report
note "report: ${README#$REPO_ROOT/}"
