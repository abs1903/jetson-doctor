#!/usr/bin/env bash
# jetson-doctor: one-shot health check for NVIDIA Jetson devices.
# Detects common misconfiguration pain points: JetPack version, nvidia runtime,
# swap, power mode, storage, thermal, Docker CDI, CUDA visibility.
#
# Usage: ./jetson-doctor.sh [-j|--json] [--fix-hints]
# Exit codes: 0 = all pass, 1 = warnings found, 2 = failures found

set -u

JSON=0
for arg in "$@"; do
  case "$arg" in
    -j|--json) JSON=1 ;;
    -h|--help)
      echo "jetson-doctor: one-shot health check for NVIDIA Jetson"
      echo "Usage: jetson-doctor.sh [-j|--json]"
      exit 0 ;;
  esac
done

# ---------- state ----------
PASS=0; WARN=0; FAIL=0
declare -a FINDINGS=()   # "LEVEL|CHECK|DETAIL|HINT"

record() { # level check detail hint
  local level="$1" check="$2" detail="$3" hint="${4:-}"
  FINDINGS+=("$level|$check|$detail|$hint")
  case "$level" in
    PASS) PASS=$((PASS+1)) ;;
    WARN) WARN=$((WARN+1)) ;;
    FAIL) FAIL=$((FAIL+1)) ;;
  esac
}

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

root_ok() { [ "$(id -u)" -eq 0 ]; }

get_model() {
  if [ -r /proc/device-tree/model ]; then
    tr -d '\0' < /proc/device-tree/model
  else
    echo "unknown"
  fi
}

get_l4t() {
  if [ -r /etc/nv_tegra_release ]; then
    # "# R36 (release), REVISION: 5.0, ..." -> "36.5.0"
    local major rev
    major=$(sed -n '1p' /etc/nv_tegra_release | grep -oE 'R[0-9]+' | head -1 | tr -d 'R')
    rev=$(grep -oE 'REVISION:[[:space:]]*[0-9.]+' /etc/nv_tegra_release | head -1 | grep -oE '[0-9.]+')
    if [ -n "$major" ] && [ -n "$rev" ]; then
      echo "${major}.${rev}"
    else
      echo "unknown-format"
    fi
  else
    echo "not-jetson"
  fi
}

jetpack_from_l4t() {
  # Known L4T -> JetPack mappings (subset; extend as new releases land)
  case "$1" in
    35.2.1) echo "5.0.2" ;;
    35.3.1) echo "5.1.1" ;;
    35.4.1) echo "5.1.2" ;;
    35.5.0) echo "5.1.3" ;;
    36.2.0) echo "6.0" ;;
    36.3.0) echo "6.1" ;;
    36.4.0) echo "6.2" ;;
    36.4.3) echo "6.2.1" ;;
    36.5.0) echo "6.2.3" ;;
    *) echo "?" ;;
  esac
}

mem_total_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo; }
swap_total_mb() { awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo; }
disk_avail_gb() { df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}'; }

gpu_temp() {
  # prefer thermal zone for the GPU complex
  for tz in /sys/class/thermal/thermal_zone*; do
    [ -r "$tz/type" ] || continue
    t=$(cat "$tz/type" 2>/dev/null)
    case "$t" in
      GPU-therm|gpu_thermal) cat "$tz/temp" 2>/dev/null && return ;;
    esac
  done
  # fallback: max of all zones
  local max=0 v
  for tz in /sys/class/thermal/thermal_zone*; do
    [ -r "$tz/temp" ] || continue
    v=$(cat "$tz/temp" 2>/dev/null) || continue
    [ "$v" -gt "$max" ] && max=$v
  done
  echo "$max"
}

power_mode() {
  if [ -r /etc/nvpmodel.conf ] && have nvpmodel; then
    nvpmodel -q 2>/dev/null | awk -F'NV Power Mode: ' '/NV Power Mode/ {print $2}'
  else
    echo "nvpmodel-missing"
  fi
}

docker_nvidia_runtime() {
  have docker || return 99
  docker info 2>/dev/null | grep -q 'nvidia' && echo yes || echo no
}

docker_cdi() {
  have docker || return 99
  if have nvidia-ctk && ls /var/run/cdi/nvidia-container-toolkit.json >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

# ---------- checks ----------
check_is_jetson() {
  local model; model=$(get_model)
  if grep -qiE 'jetson|tegra' <<<"$model"; then
    record PASS "jetson-device" "Detected: $model" ""
  else
    record FAIL "jetson-device" "This does not look like a Jetson device ($model)" "Run this on a Jetson; results will be meaningless otherwise."
  fi
}

check_jetpack() {
  local l4t jp; l4t=$(get_l4t); jp=$(jetpack_from_l4t "$l4t")
  if [ "$l4t" = "not-jetson" ]; then
    return
  fi
  if [ "$jp" = "?" ]; then
    record WARN "jetpack-version" "L4T $l4t has no JetPack mapping in this script yet" "Open an issue/PR at github.com/abs1903/jetson-doctor to add the mapping."
  else
    record PASS "jetpack-version" "L4T $l4t (JetPack $jp)" ""
  fi
}

check_nvidia_runtime() {
  local r; r=$(docker_nvidia_runtime)
  case "$r" in
    yes) record PASS "docker-nvidia-runtime" "nvidia runtime registered with Docker" "" ;;
    no)  record FAIL "docker-nvidia-runtime" "Docker present but nvidia runtime NOT registered" \
         "Install nvidia-container-toolkit, then add \"nvidia\" to /etc/docker/daemon.json runtimes and restart docker." ;;
    99)  record WARN "docker-nvidia-runtime" "Docker not installed" "Docker is the standard way to run AI stacks on Jetson (see jetson-containers)." ;;
  esac
}

check_cdi() {
  local c; c=$(docker_cdi)
  case "$c" in
    yes) record PASS "docker-cdi" "CDI nvidia device spec present" "" ;;
    no)  record WARN "docker-cdi" "CDI spec missing (needed for BuildKit GPU builds)" \
         "Run: sudo nvidia-ctk cdi generate --output=/var/run/cdi/nvidia-container-toolkit.json" ;;
    99)  return ;;
  esac
}

check_swap() {
  local mem swap
  mem=$(mem_total_mb); swap=$(swap_total_mb)
  # heuristic: unified-memory boards (4-8GB) want >=8GB disk swap for builds/inference
  if [ "$swap" -ge 8192 ]; then
    record PASS "swap-size" "Swap ${swap}MB (>= 8GB recommended)" ""
  elif [ "$swap" -ge 2048 ]; then
    record WARN "swap-size" "Swap ${swap}MB is tight for ${mem}MB RAM + big builds" \
      "Create NVMe swap: sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile (then add to /etc/fstab). Avoid swap on SD cards."
  else
    record FAIL "swap-size" "Swap ${swap}MB with ${mem}MB RAM; compilers will OOM" \
      "Create NVMe swap (16G): sudo fallocate -l 16G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile (then add to /etc/fstab)."
  fi
}

check_zram_only() {
  # warn specifically when swap is all-zram (volatile, small)
  local swap; swap=$(swap_total_mb)
  [ "$swap" -gt 0 ] || return
  if swapon --show 2>/dev/null | grep -q zram && [ "$swap" -lt 8192 ]; then
    record WARN "swap-volatile" "All swap is zram (RAM-backed, lost on reboot, capped at RAM size)" \
      "Add disk-backed swap on NVMe for heavy builds."
  fi
}

check_power_mode() {
  local m; m=$(power_mode)
  case "$m" in
    "nvpmodel-missing") record WARN "power-mode" "nvpmodel not found" "" ;;
    *MAXN*|*MAX*) record PASS "power-mode" "Power mode: $m" "" ;;
    "") record WARN "power-mode" "Could not query power mode" "" ;;
    *)  record WARN "power-mode" "Power mode '$m' is not max performance" \
        "For dev/benchmark: sudo nvpmodel -m 0 && sudo jetson_clocks (mind cooling)." ;;
  esac
}

check_thermal() {
  local t c
  t=$(gpu_temp); [ -z "$t" ] && return
  c=$(( t / 1000 ))
  if [ "$c" -ge 95 ]; then
    record FAIL "thermal" "Hot: ${c}C" "Check fan/heatsink; Jetson throttles near 100C."
  elif [ "$c" -ge 80 ]; then
    record WARN "thermal" "Warm: ${c}C" "Verify active cooling under load."
  else
    record PASS "thermal" "Temp ${c}C" ""
  fi
}

check_storage() {
  local free; free=$(disk_avail_gb)
  if [ "$free" -ge 40 ]; then
    record PASS "storage" "/ has ${free}GB free" ""
  elif [ "$free" -ge 10 ]; then
    record WARN "storage" "/ has only ${free}GB free; containers will fill this fast" \
      "docker system prune; move docker data-root to NVMe."
  else
    record FAIL "storage" "/ has only ${free}GB free" \
      "Free space or move /var/lib/docker to NVMe."
  fi
}

check_cuda() {
  if have nvcc; then
    local v; v=$(nvcc --version | grep -oE 'release [0-9.]+' | awk '{print $2}')
    record PASS "cuda-toolkit" "CUDA $v" ""
  elif [ -d /usr/local/cuda ]; then
    record WARN "cuda-toolkit" "CUDA runtime dir exists but nvcc not in PATH" \
      "Add /usr/local/cuda/bin to PATH."
  else
    record WARN "cuda-toolkit" "No CUDA toolkit found" "Install via SDK Manager or apt (nvidia-jetpack)."
  fi
}

check_cuda_in_docker() {
  have docker || return 0
  if docker info 2>/dev/null | grep -q nvidia; then
    if timeout 60 docker run --rm --runtime nvidia dustynv/jetson-inference:r36.4.0 python3 -c "import torch" >/dev/null 2>&1; then
      record PASS "docker-gpu-test" "GPU visible inside container" ""
    else
      record WARN "docker-gpu-test" "GPU test container failed (may be network/first-pull)" \
        "Try: docker run --rm --runtime nvidia dustynv/jetson-inference:r36.4.0 nvcc -V"
    fi
  fi
}

check_diskspace_docker_root() {
  have docker || return 0
  local dr; dr=$(docker info 2>/dev/null | awk '/Docker Root Dir/ {print $4}')
  [ -n "$dr" ] || return 0
  local on_root
  on_root=$(df -BG "$dr" | tail -1 | awk '{print $6}')
  if [ "$on_root" = "/" ]; then
    record WARN "docker-data-root" "Docker data on / ; containers will eat your rootfs" \
      "Consider moving data-root to NVMe in /etc/docker/daemon.json."
  else
    record PASS "docker-data-root" "Docker data on $on_root (not /)" ""
  fi
}

# ---------- output ----------
print_text() {
  echo "==============================================="
  echo " jetson-doctor report  |  $(date '+%F %T')"
  echo " $(get_model)"
  echo " L4T $(get_l4t) (JetPack $(jetpack_from_l4t "$(get_l4t)"))"
  echo "==============================================="
  local f level check detail hint
  for f in "${FINDINGS[@]}"; do
    IFS='|' read -r level check detail hint <<<"$f"
    case "$level" in
      PASS) printf " [PASS] %-22s %s\n" "$check" "$detail" ;;
      WARN) printf " [WARN] %-22s %s\n        hint: %s\n" "$check" "$detail" "$hint" ;;
      FAIL) printf " [FAIL] %-22s %s\n        hint: %s\n" "$check" "$detail" "$hint" ;;
    esac
  done
  echo "-----------------------------------------------"
  echo " $PASS passed, $WARN warnings, $FAIL failures"
}

print_json() {
  local f level check detail hint
  echo "{"
  echo "  \"model\": \"$(get_model)\","
  echo "  \"l4t\": \"$(get_l4t)\","
  echo "  \"findings\": ["
  local first=1
  for f in "${FINDINGS[@]}"; do
    IFS='|' read -r level check detail hint <<<"$f"
    detail=${detail//\"/\\\"}; hint=${hint//\"/\\\"}
    [ $first -eq 0 ] && echo ","
    first=0
    printf '    {"level":"%s","check":"%s","detail":"%s","hint":"%s"}' "$level" "$check" "$detail" "$hint"
  done
  echo ""
  echo "  ],"
  echo "  \"summary\": {\"pass\": $PASS, \"warn\": $WARN, \"fail\": $FAIL}"
  echo "}"
}

# ---------- main ----------
main() {
  check_is_jetson
  check_jetpack
  check_nvidia_runtime
  check_cdi
  check_swap
  check_zram_only
  check_power_mode
  check_thermal
  check_storage
  check_cuda
  check_diskspace_docker_root
  # check_cuda_in_docker is opt-in later; it pulls images

  if [ "$JSON" -eq 1 ]; then print_json; else print_text; fi
  if [ "$FAIL" -gt 0 ]; then exit 2; elif [ "$WARN" -gt 0 ]; then exit 1; fi
  exit 0
}

main
