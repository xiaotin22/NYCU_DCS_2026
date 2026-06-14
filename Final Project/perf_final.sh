#!/usr/bin/env bash

set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

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
  preferred="$1"
  fallback="$2"

  log_path="$(first_existing_file "$ROOT/$preferred" "$ROOT/$fallback" 2>/dev/null || true)"
  if [ -n "$log_path" ]; then
    printf '%s\n' "$log_path"
    return 0
  fi

  find "$ROOT" -maxdepth 4 -type f -name "$(basename "$fallback")" 2>/dev/null | head -n 1
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

calc_performance() {
  clk="$1"
  cycles="$2"
  area="$3"

  if ! is_number "$clk" || ! is_number "$cycles" || ! is_number "$area"; then
    printf 'NA\n'
    return 0
  fi

  awk -v clk="$clk" -v cycles="$cycles" -v area="$area" '
    BEGIN {
      printf "%.2E", clk * cycles * area
    }
  '
}

format_area() {
  value="$1"

  if ! is_number "$value"; then
    printf '%s\n' "$value"
    return 0
  fi

  printf '%s\n' "${value%%.*}"
}

format_clk() {
  value="$1"

  if ! is_number "$value"; then
    printf '%s\n' "$value"
    return 0
  fi

  awk -v value="$value" '
    BEGIN {
      if (value == int(value)) {
        printf "%d\n", value
      } else {
        print value
      }
    }
  '
}

vcs_log="$(find_log "01_RTL/vcs.log" "vcs.log")"
syn_log="$(find_log "02_SYN/syn.log" "syn.log")"

clk="NA"
cycles="NA"
area="NA"

if [ -n "$vcs_log" ] && [ -f "$vcs_log" ]; then
  cycles="$(extract_cycles "$vcs_log")"
  [ -n "$cycles" ] || cycles="NA"
fi

if [ -n "$syn_log" ] && [ -f "$syn_log" ]; then
  clk="$(extract_clk "$syn_log")"
  area="$(extract_area "$syn_log")"
  [ -n "$clk" ] || clk="NA"
  [ -n "$area" ] || area="NA"
fi

if [ "$clk" = "NA" ] && [ -n "$vcs_log" ] && [ -f "$vcs_log" ]; then
  clk="$(extract_clock_period "$vcs_log")"
  [ -n "$clk" ] || clk="NA"
fi

performance="$(calc_performance "$clk" "$cycles" "$area")"
performance="${performance/E/ E}"
clk_display="$(format_clk "$clk")"
area_display="$(format_area "$area")"

printf '\033[34m==================== Report =====================\033[0m\n'
printf '\033[36mMimi Good Job! Here is the performance summary of your design:\033[0m\n\n'
printf '\033[33mClk = %s ns\033[0m\n' "$clk_display"
printf '\033[33mLatency = %s cycle\033[0m\n' "$cycles"
printf '\033[33mArea = %s\033[0m\n' "$area_display"
printf '\033[33mPerformance = %s\033[0m\n' "$performance"
printf '\n\033[36mKeep improve !!!\033[0m\n'
printf '\033[34m===============================================================\033[0m\n'