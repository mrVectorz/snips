#!/bin/bash

# Fetch all containers on the host
containers=$(crictl ps -a -o json | jq -r '.containers | map(.id) | join(",")')
# Gather a list of all the pinned CPUs that should be isolated
ISOLATED_CPUS=""
for container in ${containers//,/ }; do
  cpu_list=$(crictl inspect $container | jq -r '.info.runtimeSpec.annotations as $anno | select($anno."irq-load-balancing.crio.io" == "disable") | select($anno."cpu-quota.crio.io" == "disable") | .status.resources.linux.cpusetCpus')
  if [[ -n $cpu_list ]]; then
    if [[ ! -n $full_cpu_list ]]; then
      ISOLATED_CPUS="${cpu_list}"
    else
      ISOLATED_CPUS="${full_cpu_list},${cpu_list}"
    fi
  fi
done
#echo $ISOLATED_CPUS

# Host CPU count
NUM_CPUS=$(nproc)

log() {
  logger -t irq-affinity "$1"
  echo "$1"
}

allowed=()
banned=()

for ((i=0; i<NUM_CPUS; i++)); do
  allowed[i]=1
  banned[i]=0
done

IFS=',' read -ra RANGES <<< "$ISOLATED_CPUS"
for range in "${RANGES[@]}"; do
  if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
      allowed[i]=0
      banned[i]=1
    done
  elif [[ "$range" =~ ^[0-9]+$ ]]; then
    allowed[$range]=0
    banned[$range]=1
  else
    log "Invalid CPU range: $range"
    exit 2
  fi
done

bits_to_hex_mask() {
  local -n bits=$1
  local mask=""
  local chunk=""

  for ((i=NUM_CPUS-1; i>=0; i--)); do
    chunk="${bits[i]}$chunk"
    if (( (${#chunk} % 32) == 0 )) || (( i == 0 )); then
      while (( ${#chunk} < 32 )); do
        chunk="0$chunk"
      done
      hex=$(printf "%08x" "$((2#$chunk))")
      mask="$hex,$mask"
      chunk=""
    fi
  done

  echo "${mask%,}"
}

allowed_mask=$(bits_to_hex_mask allowed)
banned_mask=$(bits_to_hex_mask banned)

log "Allowed IRQ CPUs mask: $allowed_mask"
log "Banned IRQ CPUs mask:  $banned_mask"

SMP_FILE="/proc/irq/default_smp_affinity"
if [ -w "$SMP_FILE" ]; then
  current_mask=$(cat "$SMP_FILE" | tr 'A-Z' 'a-z')
  if [[ "$current_mask" != "${allowed_mask,,}" ]]; then
    echo "$allowed_mask" > "$SMP_FILE"
    log "Updated $SMP_FILE"
  else
    log "No change to $SMP_FILE"
  fi
else
  log "Permission denied: cannot write to $SMP_FILE"
fi

IRQBALANCE_CONF="/etc/sysconfig/irqbalance"
RESTART_IRQBALANCE=false

if [ -w "$IRQBALANCE_CONF" ]; then
  existing_mask=$(grep '^IRQBALANCE_BANNED_CPUS=' "$IRQBALANCE_CONF" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr 'A-Z' 'a-z')

  if [[ "$existing_mask" != "${banned_mask,,}" ]]; then
    if grep -q '^IRQBALANCE_BANNED_CPUS=' "$IRQBALANCE_CONF"; then
      sed -i "s/^IRQBALANCE_BANNED_CPUS=.*/IRQBALANCE_BANNED_CPUS=\"$banned_mask\"/" "$IRQBALANCE_CONF"
    else
      echo "IRQBALANCE_BANNED_CPUS=\"$banned_mask\"" >> "$IRQBALANCE_CONF"
    fi
    log "Updated $IRQBALANCE_CONF"
    RESTART_IRQBALANCE=true
  else
    log "No change to $IRQBALANCE_CONF"
  fi
else
  log "Permission denied: cannot write to $IRQBALANCE_CONF"
fi

if $RESTART_IRQBALANCE; then
  if systemctl is-active --quiet irqbalance; then
    log "Restarting irqbalance service..."
    systemctl restart irqbalance && log "irqbalance restarted successfully"
  else
    log "irqbalance is not active; skipping restart"
  fi
fi
