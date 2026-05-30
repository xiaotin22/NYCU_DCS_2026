#!/usr/bin/env bash

set -u

ROOT="${1:-.}"

add_target_dir() {
  candidate="$1"
  [ -d "$candidate" ] || return 0

  case "$(basename "$candidate")" in
    HW0*|DCS_HW0*|FINAL*|Final*|final*|DCS_FINAL*|DCS_Final*|DCS_final*)
      target_dirs="${target_dirs}${candidate}
"
      ;;
  esac
}

is_number() {
  case "$1" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
    *) return 0 ;;
  esac
}

first_existing_file() {
  for path in "$@"; do
    if [ -f "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

find_log() {
  hw_dir="$1"
  preferred="$2"
  fallback="$3"

  log_path="$(first_existing_file "$hw_dir/$preferred" "$hw_dir/$fallback" 2>/dev/null || true)"
  if [ -n "$log_path" ]; then
    printf '%s\n' "$log_path"
    return 0
  fi

  find "$hw_dir" -maxdepth 4 -type f -name "$(basename "$fallback")" 2>/dev/null | head -n 1
}

extract_number_by_pattern() {
  log_file="$1"
  pattern="$2"
  mode="$3"

  awk -v pattern="$pattern" -v mode="$mode" '
    {
      line = tolower($0)
      if (line !~ pattern) next

      target = $0
      if (target ~ /[:=]/) {
        sub(/^.*[:=][[:space:]]*/, "", target)
      }

      n = split(target, fields, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        token = fields[i]
        gsub(/[^0-9.]/, "", token)
        if (token ~ /^[0-9]+(\.[0-9]+)?$/) {
          if (mode == "first") {
            print token
            exit
          }
          value = token
          break
        }
      }
    }
    END {
      if (mode != "first" && value != "") print value
    }
  ' "$log_file"
}

extract_cycles() {
  log_file="$1"

  cycles="$(extract_number_by_pattern "$log_file" "execution[ _-]*cycles" "last")"
  if [ -n "$cycles" ]; then
    printf '%s\n' "$cycles"
    return 0
  fi

  cycles="$(extract_number_by_pattern "$log_file" "total[ _-]*cycle" "last")"
  if [ -n "$cycles" ]; then
    printf '%s\n' "$cycles"
    return 0
  fi

  extract_number_by_pattern "$log_file" "cycle[ _-]*latency|latency[ _-]*cycle|latency[[:space:]]*[:=].*cycle|latecny[[:space:]]*[:=].*cycle" "last"
}

extract_latency_ns() {
  log_file="$1"

  extract_number_by_pattern "$log_file" "total[[:space:]]+latency.*ns|latency[[:space:]]*[:=].*ns|latecny[[:space:]]*[:=].*ns" "last"
}

extract_clock_period() {
  log_file="$1"

  extract_number_by_pattern "$log_file" "clock[ _-]*period.*ns" "last"
}

extract_clk() {
  log_file="$1"

  clk="$(awk '
    {
      line = tolower($0)
      if (line !~ /^[[:space:]]*set[[:space:]]+cycle[[:space:]]+/) next
      for (i = 1; i <= NF; i++) {
        token = $i
        gsub(/[^0-9.]/, "", token)
        if (token ~ /^[0-9]+(\.[0-9]+)?$/) {
          print token
          exit
        }
      }
    }
  ' "$log_file")"

  if [ -n "$clk" ]; then
    printf '%s\n' "$clk"
    return 0
  fi

  awk '
    /clock clk \(rise edge\)/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/ && $i + 0 > 0) {
          clk = $i
        }
      }
    }
    END {
      if (clk != "") print clk
    }
  ' "$log_file"
}

extract_area() {
  log_file="$1"

  area="$(awk '
    {
      line = tolower($0)
      if (line !~ /total cell area:/) next
      for (i = NF; i >= 1; i--) {
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          print $i
          exit
        }
      }
    }
  ' "$log_file")"

  if [ -n "$area" ]; then
    printf '%s\n' "$area"
    return 0
  fi

  awk '
    {
      line = tolower($0)
      if (line !~ /total area:/) next
      for (i = NF; i >= 1; i--) {
        if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {
          print $i
          exit
        }
      }
    }
  ' "$log_file"
}

normalize_target() {
  target_name="$(basename "$1")"

  case "$target_name" in
    DCS_HW0*)
      printf 'HW%s\n' "${target_name#DCS_HW}"
      ;;
    HW0*)
      printf '%s\n' "$target_name"
      ;;
    FINAL*|Final*|final*|DCS_FINAL*|DCS_Final*|DCS_final*)
      printf 'FINAL\n'
      ;;
    *)
      printf '%s\n' "$target_name"
      ;;
  esac
}

performance_formula() {
  target_key="$(normalize_target "$1")"

  # Edit this case block when each assignment needs a different formula.
  # Available variables: clk (ns), cycle/cycles, latency (ns), area.
  case "$target_key" in
    HW01)
      printf 'area\n'
      ;;
    HW02)
      printf 'cycle * area\n'
      ;;
    HW03)
      printf 'cycle * area * area\n'
      ;;
    HW04)
      printf 'clk * cycle * area * area\n'
      ;;
    HW05)
      printf 'clk * clk * cycle * cycle * area\n'
      ;;
    FINAL)
      printf 'clk * cycle * area\n'
      ;;
    *)
      printf 'clk * cycle * area\n'
      ;;
  esac
}

formula_uses() {
  formula="$1"
  variable="$2"

  awk -v formula="$formula" -v variable="$variable" '
    BEGIN {
      pattern = "(^|[^A-Za-z0-9_])" variable "([^A-Za-z0-9_]|$)"
      exit (formula ~ pattern ? 0 : 1)
    }
  '
}

formula_has_missing_value() {
  formula="$1"
  clk="$2"
  cycles="$3"
  latency="$4"
  area="$5"

  if formula_uses "$formula" "clk" && ! is_number "$clk"; then
    return 0
  fi

  if { formula_uses "$formula" "cycle" || formula_uses "$formula" "cycles"; } && ! is_number "$cycles"; then
    return 0
  fi

  if formula_uses "$formula" "latency" && ! is_number "$latency"; then
    return 0
  fi

  if formula_uses "$formula" "area" && ! is_number "$area"; then
    return 0
  fi

  return 1
}

calc_score() {
  target="$1"
  clk="$2"
  cycles="$3"
  latency="$4"
  area="$5"
  formula="$(performance_formula "$target")"

  if formula_has_missing_value "$formula" "$clk" "$cycles" "$latency" "$area"; then
    printf 'NA\n'
    return 0
  fi

  awk -v clk="$clk" -v cycle="$cycles" -v cycles="$cycles" -v latency="$latency" -v area="$area" "
    BEGIN {
      printf \"%.6e\", $formula
    }
  "
}

printf '%-12s %-12s %-14s %-14s %-16s %-16s %-18s\n' "TARGET" "CLK(ns)" "CYCLES" "LATENCY(ns)" "AREA" "PERFORMANCE" "STATUS"
printf '%-12s %-12s %-14s %-14s %-16s %-16s %-18s\n' "------------" "------------" "--------------" "--------------" "----------------" "----------------" "------------------"

summary=""
found=0
target_dirs=""

add_target_dir "$ROOT"
for target_dir in "$ROOT"/HW0* "$ROOT"/DCS_HW0* "$ROOT"/FINAL* "$ROOT"/Final* "$ROOT"/final* "$ROOT"/DCS_FINAL* "$ROOT"/DCS_Final* "$ROOT"/DCS_final*; do
  [ -d "$target_dir" ] || continue
  add_target_dir "$target_dir"
done

if [ -z "$target_dirs" ] && [ "$#" -eq 0 ]; then
  for target_dir in "$HOME"/HW0* "$HOME"/DCS_HW0* "$HOME"/FINAL* "$HOME"/Final* "$HOME"/final* "$HOME"/DCS_FINAL* "$HOME"/DCS_Final* "$HOME"/DCS_final*; do
    [ -d "$target_dir" ] || continue
    add_target_dir "$target_dir"
  done
fi

while IFS= read -r target_dir; do
  [ -n "$target_dir" ] || continue
  found=1

  target_name="$(basename "$target_dir")"
  formula_text="$(performance_formula "$target_name")"

  vcs_log="$(find_log "$target_dir" "01_RTL/vcs.log" "vcs.log")"
  syn_log="$(find_log "$target_dir" "02_SYN/syn.log" "syn.log")"
  status="ok"

  cycles="NA"
  latency="NA"
  clk="NA"
  area="NA"

  if [ -n "$vcs_log" ] && [ -f "$vcs_log" ]; then
    cycles="$(extract_cycles "$vcs_log")"
    latency="$(extract_latency_ns "$vcs_log")"
    [ -n "$cycles" ] || cycles="NA"
    [ -n "$latency" ] || latency="NA"
  else
    status="missing vcs.log"
  fi

  if [ -n "$syn_log" ] && [ -f "$syn_log" ]; then
    clk="$(extract_clk "$syn_log")"
    area="$(extract_area "$syn_log")"
    [ -n "$clk" ] || clk="NA"
    [ -n "$area" ] || area="NA"
  elif [ "$status" = "ok" ]; then
    status="missing syn.log"
  else
    status="missing logs"
  fi

  if [ "$clk" = "NA" ] && [ -n "$vcs_log" ] && [ -f "$vcs_log" ]; then
    clk="$(extract_clock_period "$vcs_log")"
    [ -n "$clk" ] || clk="NA"
  fi

  if [ "$latency" = "NA" ] && is_number "$clk" && is_number "$cycles"; then
    latency="$(awk -v clk="$clk" -v cycles="$cycles" 'BEGIN { printf "%.6g", clk * cycles }')"
  fi

  if [ "$status" = "ok" ] && formula_has_missing_value "$formula_text" "$clk" "$cycles" "$latency" "$area"; then
    status="parse warning"
  fi

  score="$(calc_score "$target_name" "$clk" "$cycles" "$latency" "$area")"

  latency_summary="latency=${latency}ns"
  if [ "$latency" = "NA" ]; then
    latency_summary="latency=NA"
  fi

  printf '%-12s %-12s %-14s %-14s %-16s %-16s %-18s\n' "$target_name" "$clk" "$cycles" "$latency" "$area" "$score" "$status"
  summary="${summary}- ${target_name}: clk=${clk}ns, cycles=${cycles}, ${latency_summary}, area=${area}, performance=${score}, formula=${formula_text}, status=${status}
"
done <<EOF
$target_dirs
EOF

if [ "$found" -eq 0 ]; then
  printf '\nNo HW0*/DCS_HW0*/Final/DCS_FINAL directories found under %s\n' "$ROOT"
fi

printf '\nCommit message:\n'
printf '%s\n' '----------------------------------------'
printf 'perf: update performance results\n\n'
printf 'Formula variables: clk(ns), cycle/cycles, latency(ns), area\n\n'
printf '%s' "$summary"
printf '%s\n' '----------------------------------------'
