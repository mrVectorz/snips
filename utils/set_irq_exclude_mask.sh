#!/bin/bash

# Usage: sudo ./set_irq_affinity_masks.sh "94-101,198-205"

if [ -z "$1" ]; then
  echo "Usage: $0 <isolated_cpus>"
  echo "Example: $0 \"94-101,198-205\""
  exit 1
fi

ISOLATED_CPUS="$1"
# NUM_CPUS=$(nproc)
NUM_CPUS=208 #test

# Initialize bit arrays
allowed=()
banned=()

for ((i=0; i<NUM_CPUS; i++)); do
  allowed[i]=1
  banned[i]=0
done

# Parse CPU ranges and update masks
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
    echo "Invalid CPU range: $range"
    exit 2
  fi
done

# Function to convert bit array to little-endian hex mask
bits_to_hex_mask() {
  local -n bits=$1
  local mask=""
  local chunk=""

  for ((i=NUM_CPUS-1; i>=0; i--)); do
    chunk="${bits[i]}$chunk"
    # Every 32 bits, flush to hex
    if (( (${#chunk} % 32) == 0 )) || (( i == 0 )); then
      # Pad if needed
      while (( ${#chunk} < 32 )); do
        chunk="0$chunk"
      done
      hex=$(printf "%08x" "$((2#$chunk))")
      mask="$hex,$mask"
      chunk=""
    fi
  done

  # Remove trailing comma
  echo "${mask%,}"
}

allowed_mask=$(bits_to_hex_mask allowed)
banned_mask=$(bits_to_hex_mask banned)

echo "Allowed IRQ CPUs mask: $allowed_mask"
echo "Banned IRQ CPUs mask:  $banned_mask"

# Write to /proc/irq/default_smp_affinity
SMP_AFFINITY_CONF="default_smp_affinity"
#SMP_AFFINITY_CONF="/proc/irq/default_smp_affinity"
if [ -w $SMP_AFFINITY_CONF ]; then
  echo "$allowed_mask" > $SMP_AFFINITY_CONF
  echo "Written to $SMP_AFFINITY_CONF"
else
  echo "Permission denied: cannot write to $SMP_AFFINITY_CONF"
fi

# Write to /etc/sysconfig/irqbalance
#IRQBALANCE_CONF="/etc/sysconfig/irqbalance"
IRQBALANCE_CONF="irqbalance"
if [ -w "$IRQBALANCE_CONF" ]; then
  if grep -q '^IRQBALANCE_BANNED_CPUS=' "$IRQBALANCE_CONF"; then
    sed -i "s/^IRQBALANCE_BANNED_CPUS=.*/IRQBALANCE_BANNED_CPUS=\"$banned_mask\"/" "$IRQBALANCE_CONF"
  else
    echo "IRQBALANCE_BANNED_CPUS=\"$banned_mask\"" >> "$IRQBALANCE_CONF"
  fi
  echo "Written to $IRQBALANCE_CONF"
else
  echo "Permission denied: cannot write to $IRQBALANCE_CONF"
fi
