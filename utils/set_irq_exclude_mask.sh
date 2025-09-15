#!/bin/bash

# Parse command line arguments
LOCAL_MODE=false
BASE_DIR="."

while [[ $# -gt 0 ]]; do
  case $1 in
    --local)
      LOCAL_MODE=true
      if [[ -n $2 && $2 != -* ]]; then
        BASE_DIR="$2"
        shift 2
      else
        echo "Error: --local requires a directory argument"
        exit 1
      fi
      ;;
    -h|--help)
      echo "Usage: $0 [--local /path/to/sosreport]"
      echo "  --local DIR   Run against sosreport directory instead of live host"
      echo "  -h, --help    Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use -h or --help for usage information"
      exit 1
      ;;
  esac
done

# Ensure base directory exists
if [[ ! -d "$BASE_DIR" ]]; then
  echo "Error: Directory '$BASE_DIR' does not exist"
  exit 1
fi

# Gather a list of all the pinned CPUs that should be isolated
ISOLATED_CPUS=""
full_cpu_list=""

if [[ "$LOCAL_MODE" == "true" ]]; then
  # Running against sosreport
  CONTAINERS_DIR="$BASE_DIR/sos_commands/crio/containers"
  if [[ -d "$CONTAINERS_DIR" ]]; then
    for container in $(ls "$CONTAINERS_DIR" 2>/dev/null); do
      cpu_list=$(cat "$CONTAINERS_DIR/$container" 2>/dev/null | jq -r '.info.runtimeSpec.annotations as $anno | select($anno."irq-load-balancing.crio.io" == "disable") | select($anno."cpu-quota.crio.io" == "disable") | .status.resources.linux.cpusetCpus' 2>/dev/null)
      if [[ -n $cpu_list && $cpu_list != "null" ]]; then
        if [[ ! -n $full_cpu_list ]]; then
          ISOLATED_CPUS="${cpu_list}"
        else
          ISOLATED_CPUS="${full_cpu_list},${cpu_list}"
        fi
        full_cpu_list=${ISOLATED_CPUS}
      fi
    done
  else
    echo "Warning: Container directory '$CONTAINERS_DIR' not found"
  fi
else
  # Running on live host - fetch all containers
  containers=$(crictl ps -a -o json | jq -r '.containers | map(.id) | join(",")')
  IFS=',' read -ra CONTAINER_IDS <<< "$containers"
  for container_id in "${CONTAINER_IDS[@]}"; do
    cpu_list=$(crictl inspect "$container_id" | jq -r '.info.runtimeSpec.annotations as $anno | select($anno."irq-load-balancing.crio.io" == "disable") | select($anno."cpu-quota.crio.io" == "disable") | .status.resources.linux.cpusetCpus' 2>/dev/null)
    if [[ -n $cpu_list && $cpu_list != "null" ]]; then
      if [[ ! -n $full_cpu_list ]]; then
        ISOLATED_CPUS="${cpu_list}"
      else
        ISOLATED_CPUS="${full_cpu_list},${cpu_list}"
      fi
      full_cpu_list=${ISOLATED_CPUS}
    fi
  done
fi

format_cpu_list() {
  local cpu_list="$1"
  if [[ -z "$cpu_list" ]]; then
    echo ""
    return
  fi
  
  # Convert comma-separated list to array and sort numerically
  IFS=',' read -ra CPUS <<< "$cpu_list"
  IFS=$'\n' sorted_cpus=($(sort -n <<<"${CPUS[*]}"))
  
  local formatted=""
  local range_start=""
  local range_end=""
  local i=0
  
  while [[ $i -lt ${#sorted_cpus[@]} ]]; do
    local current=${sorted_cpus[i]}
    range_start=$current
    range_end=$current
    
    # Find consecutive CPUs to form a range
    while [[ $((i+1)) -lt ${#sorted_cpus[@]} && ${sorted_cpus[$((i+1))]} -eq $((current+1)) ]]; do
      i=$((i+1))
      current=${sorted_cpus[i]}
      range_end=$current
    done
    
    # Format the range
    if [[ $range_start -eq $range_end ]]; then
      # Single CPU
      if [[ -n "$formatted" ]]; then
        formatted="$formatted, $range_start"
      else
        formatted="$range_start"
      fi
    else
      # Range of CPUs
      if [[ -n "$formatted" ]]; then
        formatted="$formatted, $range_start-$range_end"
      else
        formatted="$range_start-$range_end"
      fi
    fi
    
    i=$((i+1))
  done
  
  echo "$formatted"
}

normalize_hex_mask() {
  local mask="$1"
  local normalized=""
  
  IFS=',' read -ra HEX_GROUPS <<< "$mask"
  for group in "${HEX_GROUPS[@]}"; do
    # Pad each group to exactly 8 characters with leading zeros (don't strip!)
    while [[ ${#group} -lt 8 ]]; do
      group="0$group"
    done
    
    if [[ -n "$normalized" ]]; then
      normalized="$normalized,$group"
    else
      normalized="$group"
    fi
  done
  
  echo "$normalized"
}

log() {
  logger -t irq-affinity "$1"
  echo "$1"
}

FORMATTED_ISOLATED_CPUS=$(format_cpu_list "$ISOLATED_CPUS")

log "========================================="
log "IRQ Affinity Configuration Analysis"
log "========================================="
log ""
log "CONTAINER ANALYSIS:"
if [[ -n "$FORMATTED_ISOLATED_CPUS" ]]; then
  log "  CPUs to isolate from IRQs: $FORMATTED_ISOLATED_CPUS"
else
  log "  No CPUs found requiring IRQ isolation"
fi

# Host CPU count
if [[ "$LOCAL_MODE" == "true" ]]; then
  CPUINFO_FILE="$BASE_DIR/proc/cpuinfo"
  if [[ -f "$CPUINFO_FILE" ]]; then
    NUM_CPUS=$(awk 'BEGIN {processor=0}; {if ($1 ~ /processor/){processor=$3}}; END {print processor+1}' "$CPUINFO_FILE")
  else
    echo "Error: CPU info file '$CPUINFO_FILE' not found"
    exit 1
  fi
else
  NUM_CPUS=$(nproc --all)
fi

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

# Generate mask for kernel consumption (standard kernel parsing)
generate_kernel_mask() {
  local -n bits=$1
  local mask=""
  local group_masks=()
  
  # Process CPUs in groups of 32, starting from CPU 0
  local group_num=0
  while (( group_num * 32 < NUM_CPUS )); do
    local start_cpu=$((group_num * 32))
    local end_cpu=$(((group_num + 1) * 32 - 1))
    if (( end_cpu >= NUM_CPUS )); then
      end_cpu=$((NUM_CPUS - 1))
    fi
    
    # Initialize 32-bit value for this group
    local group_value=0
    
    # Map each CPU to its bit position using kernel's pattern
    for ((cpu=start_cpu; cpu<=end_cpu && cpu<NUM_CPUS; cpu++)); do
      if [[ ${bits[cpu]} -eq 1 ]]; then
        local relative_pos=$((cpu - start_cpu))
        # Use direct bit mapping: CPU position within group = bit position
        group_value=$((group_value | (1 << relative_pos)))
      fi
    done
    
    # Convert to hex (no byte swapping needed)
    local hex=$(printf "%08x" "$group_value")
    
    group_masks[group_num]="$hex"
    group_num=$((group_num + 1))
  done
  
  # Build final mask with highest group first (big-endian format)
  # First group strips leading zeros, others keep full format (like kernel)
  for ((i=${#group_masks[@]}-1; i>=0; i--)); do
    local group="${group_masks[i]}"
    if [[ -z "$mask" ]]; then
      # First (highest) group: strip leading zeros but keep at least one digit
      group=$(echo "$group" | sed 's/^0*//' | sed 's/^$/0/')
      mask="$group"
    else
      # Other groups: keep full 8-digit format
      mask="$mask,$group"
    fi
  done
  
  echo "$mask"
}

# Generate mask for irqbalance consumption (accounting for parsing bug)
generate_irqbalance_mask() {
  local -n bits=$1
  local mask=""
  local group_masks=()
  
  # Process CPUs in groups of 32, starting from CPU 0
  local group_num=0
  while (( group_num * 32 < NUM_CPUS )); do
    local start_cpu=$((group_num * 32))
    local end_cpu=$(((group_num + 1) * 32 - 1))
    if (( end_cpu >= NUM_CPUS )); then
      end_cpu=$((NUM_CPUS - 1))
    fi
    
    # Initialize 32-bit value for this group
    local group_value=0
    
    # Map each CPU to its bit position using kernel's pattern
    for ((cpu=start_cpu; cpu<=end_cpu && cpu<NUM_CPUS; cpu++)); do
      if [[ ${bits[cpu]} -eq 1 ]]; then
        local relative_pos=$((cpu - start_cpu))
        # Use direct bit mapping: CPU position within group = bit position
        group_value=$((group_value | (1 << relative_pos)))
      fi
    done
    
    # Convert to hex (no byte swapping needed)
    local hex=$(printf "%08x" "$group_value")
    
    group_masks[group_num]="$hex"
    group_num=$((group_num + 1))
  done
  
  # Build final mask accounting for irqbalance's parsing bug
  # WORKAROUND: For irqbalance, we may need different formatting to handle parsing bugs
  # For now, use same logic as kernel until we see actual differences in behavior
  for ((i=${#group_masks[@]}-1; i>=0; i--)); do
    local group="${group_masks[i]}"
    if [[ -z "$mask" ]]; then
      # First (highest) group: strip leading zeros but keep at least one digit  
      group=$(echo "$group" | sed 's/^0*//' | sed 's/^$/0/')
      mask="$group"
    else
      # Other groups: keep full 8-digit format
      mask="$mask,$group"
    fi
  done
  
  echo "$mask"
}

# Legacy function for backward compatibility
bits_to_hex_mask() {
  generate_kernel_mask "$1"
}

# Generate masks for different targets
kernel_allowed_mask=$(generate_kernel_mask allowed)
kernel_banned_mask=$(generate_kernel_mask banned)
irqbalance_allowed_mask=$(generate_irqbalance_mask allowed)
irqbalance_banned_mask=$(generate_irqbalance_mask banned)

# Create formatted CPU lists from the arrays
allowed_cpus=""
banned_cpus=""
for ((i=0; i<NUM_CPUS; i++)); do
  if [[ ${allowed[i]} -eq 1 ]]; then
    if [[ -n "$allowed_cpus" ]]; then
      allowed_cpus="$allowed_cpus,$i"
    else
      allowed_cpus="$i"
    fi
  fi
  if [[ ${banned[i]} -eq 1 ]]; then
    if [[ -n "$banned_cpus" ]]; then
      banned_cpus="$banned_cpus,$i"
    else
      banned_cpus="$i"
    fi
  fi
done

formatted_allowed_cpus=$(format_cpu_list "$allowed_cpus")
formatted_banned_cpus=$(format_cpu_list "$banned_cpus")

log ""
log "COMPUTED IRQ CONFIGURATION:"
log "  Allowed IRQ CPUs:"
log "    Kernel mask (/proc/irq/default_smp_affinity): $kernel_allowed_mask"
log "    irqbalance mask (IRQBALANCE_BANNED_CPUS uses banned): $irqbalance_allowed_mask"
log "    CPUs: $formatted_allowed_cpus"
log "  Banned IRQ CPUs:"
log "    Kernel mask: $kernel_banned_mask"
log "    irqbalance mask (IRQBALANCE_BANNED_CPUS): $irqbalance_banned_mask"
log "    CPUs: $formatted_banned_cpus"

if [[ "$LOCAL_MODE" == "true" ]]; then
  log ""
  log "CURRENT SYSTEM STATE (from sosreport):"
  
  # Check if sosreport contains current irq configuration for comparison
  SMP_FILE="$BASE_DIR/proc/irq/default_smp_affinity"
  if [[ -f "$SMP_FILE" ]]; then
    current_mask=$(cat "$SMP_FILE" | tr 'A-Z' 'a-z')
    log "  /proc/irq/default_smp_affinity: $current_mask"
  else
    log "  /proc/irq/default_smp_affinity: [FILE NOT FOUND]"
  fi

  # Check irqbalance configuration if available in sosreport
  IRQBALANCE_CONF="$BASE_DIR/etc/sysconfig/irqbalance"
  if [[ -f "$IRQBALANCE_CONF" ]]; then
    existing_mask=$(grep '^IRQBALANCE_BANNED_CPUS=' "$IRQBALANCE_CONF" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr 'A-Z' 'a-z')
    if [[ -n "$existing_mask" ]]; then
      log "  IRQBALANCE_BANNED_CPUS: $existing_mask"
    else
      log "  IRQBALANCE_BANNED_CPUS: [NOT SET]"
    fi
  else
    log "  /etc/sysconfig/irqbalance: [FILE NOT FOUND]"
  fi
  
  log ""
  log "RECOMMENDATIONS:"
  
  # Compare and recommend changes for default_smp_affinity
  if [[ -f "$SMP_FILE" ]]; then
    normalized_current=$(normalize_hex_mask "$current_mask")
    normalized_allowed=$(normalize_hex_mask "${kernel_allowed_mask,,}")
    if [[ "$normalized_current" != "$normalized_allowed" ]]; then
      log "  ✗ UPDATE REQUIRED: /proc/irq/default_smp_affinity"
      log "    Current:  $current_mask"
      log "    Required: ${kernel_allowed_mask,,}"
    else
      log "  ✓ CORRECT: /proc/irq/default_smp_affinity is already properly configured"
    fi
  else
    log "  ✗ CREATE REQUIRED: /proc/irq/default_smp_affinity = ${kernel_allowed_mask,,}"
  fi

  # Compare and recommend changes for irqbalance
  if [[ -f "$IRQBALANCE_CONF" ]]; then
    if [[ -n "$existing_mask" ]]; then
      if [[ "$existing_mask" != "${irqbalance_banned_mask,,}" ]]; then
        log "  ✗ UPDATE REQUIRED: IRQBALANCE_BANNED_CPUS"
        log "    Current:  $existing_mask"
        log "    Required: ${irqbalance_banned_mask,,}"
      else
        log "  ✓ CORRECT: IRQBALANCE_BANNED_CPUS is already properly configured"
      fi
    else
      log "  ✗ ADD REQUIRED: IRQBALANCE_BANNED_CPUS=\"${irqbalance_banned_mask,,}\""
    fi
  else
    log "  ✗ CREATE REQUIRED: /etc/sysconfig/irqbalance with IRQBALANCE_BANNED_CPUS=\"${irqbalance_banned_mask,,}\""
  fi
  
  log ""
  log "NOTE: Running in analysis mode - no changes will be made to the system"
  
  log ""
  log "========================================="
  log "Analysis Complete"
  log "========================================="
  
  exit 0
fi

# Live system modifications (only when not in local mode)
log ""
log "CURRENT SYSTEM STATE (live system):"

SMP_FILE="/proc/irq/default_smp_affinity"
if [ -r "$SMP_FILE" ]; then
  current_smp_mask=$(cat "$SMP_FILE" | tr 'A-Z' 'a-z')
  log "  /proc/irq/default_smp_affinity: $current_smp_mask"
else
  log "  /proc/irq/default_smp_affinity: [CANNOT READ]"
fi

IRQBALANCE_CONF="/etc/sysconfig/irqbalance"
if [ -r "$IRQBALANCE_CONF" ]; then
  existing_irq_mask=$(grep '^IRQBALANCE_BANNED_CPUS=' "$IRQBALANCE_CONF" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr 'A-Z' 'a-z')
  if [[ -n "$existing_irq_mask" ]]; then
    log "  IRQBALANCE_BANNED_CPUS: $existing_irq_mask"
  else
    log "  IRQBALANCE_BANNED_CPUS: [NOT SET]"
  fi
else
  log "  /etc/sysconfig/irqbalance: [CANNOT READ]"
fi

log ""
log "APPLYING CHANGES:"

RESTART_IRQBALANCE=false

# Update /proc/irq/default_smp_affinity
if [ -w "$SMP_FILE" ]; then
  normalized_current=$(normalize_hex_mask "$current_smp_mask")
  normalized_allowed=$(normalize_hex_mask "${kernel_allowed_mask,,}")
  if [[ "$normalized_current" != "$normalized_allowed" ]]; then
    echo "$kernel_allowed_mask" > "$SMP_FILE"
    log "  ✓ UPDATED: /proc/irq/default_smp_affinity"
    log "    Previous: $current_smp_mask"
    log "    New:      ${kernel_allowed_mask,,}"
  else
    log "  ✓ NO CHANGE: /proc/irq/default_smp_affinity already correct"
  fi
else
  log "  ✗ FAILED: Cannot write to $SMP_FILE (permission denied)"
fi

# Update irqbalance configuration
if [ -w "$IRQBALANCE_CONF" ]; then
  if [[ "$existing_irq_mask" != "${irqbalance_banned_mask,,}" ]]; then
    if grep -q '^IRQBALANCE_BANNED_CPUS=' "$IRQBALANCE_CONF"; then
      sed -i "s/^IRQBALANCE_BANNED_CPUS=.*/IRQBALANCE_BANNED_CPUS=\"$irqbalance_banned_mask\"/" "$IRQBALANCE_CONF"
      log "  ✓ UPDATED: IRQBALANCE_BANNED_CPUS in $IRQBALANCE_CONF"
    else
      echo "IRQBALANCE_BANNED_CPUS=\"$irqbalance_banned_mask\"" >> "$IRQBALANCE_CONF"
      log "  ✓ ADDED: IRQBALANCE_BANNED_CPUS to $IRQBALANCE_CONF"
    fi
    if [[ -n "$existing_irq_mask" ]]; then
      log "    Previous: $existing_irq_mask"
    else
      log "    Previous: [NOT SET]"
    fi
    log "    New:      ${irqbalance_banned_mask,,}"
    RESTART_IRQBALANCE=true
  else
    log "  ✓ NO CHANGE: IRQBALANCE_BANNED_CPUS already correct"
  fi
else
  log "  ✗ FAILED: Cannot write to $IRQBALANCE_CONF (permission denied)"
fi

# Restart irqbalance service if needed
if $RESTART_IRQBALANCE; then
  log ""
  log "SERVICE RESTART:"
  if systemctl is-active --quiet irqbalance; then
    log "  Restarting irqbalance service..."
    if systemctl restart irqbalance; then
      log "  ✓ SUCCESS: irqbalance service restarted"
    else
      log "  ✗ FAILED: irqbalance service restart failed"
    fi
  else
    log "  ⚠ SKIPPED: irqbalance service is not active"
  fi
fi

log ""
log "========================================="
log "Configuration Complete"
log "========================================="
