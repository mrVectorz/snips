#!/bin/bash
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <duration_mins> <pci_address1> [pci_address2] ..."
    exit 1
fi

DURATION_MINS=$1
shift
PCI_ADDRESSES=("$@")

# --- Configuration ---
LOG_DIR="capture_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

ETHTOOL_LOG="$LOG_DIR/ethtool_stats.log"
IB_ALL_LOG="$LOG_DIR/all_ib_counters.log"
IB_HW_LOG="$LOG_DIR/hw_buffer_counters.log"
INTERRUPTS_LOG="$LOG_DIR/interrupts.log"
SOFTIRQS_LOG="$LOG_DIR/softirqs.log"
TURBO_LOG="$LOG_DIR/turbostat.log"

IB_INTERVAL=1
ETHTOOL_INTERVAL=10

# --- PF Mapping ---
RAW_DEVICES=""
for pci in "${PCI_ADDRESSES[@]}"; do
    PF_PATH=$(readlink -f "/sys/bus/pci/devices/$pci/physfn" 2>/dev/null || echo "/sys/bus/pci/devices/$pci")
    PF_NAME=$(ls "$PF_PATH/net" 2>/dev/null | head -n 1)
    [ -n "$PF_NAME" ] && RAW_DEVICES+="$PF_NAME "
done
ROOT_DEVICES=$(echo "$RAW_DEVICES" | tr ' ' '\n' | sort -u)

# --- Start Turbostat in Background ---
TOTAL_ITERATIONS=$(( DURATION_MINS * 60 ))
echo "Starting turbostat for $TOTAL_ITERATIONS iterations..."
turbostat -i 1 --num_iterations "$TOTAL_ITERATIONS" > "$TURBO_LOG" 2>&1 &
TURBO_PID=$!

END_TIME=$(( SECONDS + (DURATION_MINS * 60) ))
NEXT_ETHTOOL=$SECONDS

echo "Starting collection into: $LOG_DIR"

while [ $SECONDS -lt $END_TIME ]; do
    CUR_TIME=$SECONDS
    TIMESTAMP_SEC=$(date +'%s')
    TIMESTAMP_HUMAN=$(date "+%Y-%m-%d %H:%M:%S")

    # IB & HW Counters
    echo "=== $TIMESTAMP_SEC ===" >> "$IB_ALL_LOG"
    grep -H . /sys/class/infiniband/mlx5_*/ports/*/*counters/* >> "$IB_ALL_LOG" 2>/dev/null

    grep -H . /sys/class/infiniband/mlx5_*/ports/1/hw_counters/*buffer* 2>/dev/null | \
        sed 's|.*/mlx5_|mlx5_|; s|/ports/1/hw_counters/| |; s|:| |' | \
        column -t >> "$IB_HW_LOG"

    # Proc Stats
    echo "=== $TIMESTAMP_HUMAN ===" >> "$INTERRUPTS_LOG"
    cat /proc/interrupts >> "$INTERRUPTS_LOG"
    echo "=== $TIMESTAMP_HUMAN ===" >> "$SOFTIRQS_LOG"
    cat /proc/softirqs >> "$SOFTIRQS_LOG"

    # Ethtool Stats (Every 10s)
    if [ $CUR_TIME -ge $NEXT_ETHTOOL ]; then
        for dev in $ROOT_DEVICES; do
            echo "=== $TIMESTAMP_HUMAN | Device: $dev ===" >> "$ETHTOOL_LOG"
            ethtool -S "$dev" | grep -v ' 0$' >> "$ETHTOOL_LOG"
        done
        NEXT_ETHTOOL=$(( CUR_TIME + ETHTOOL_INTERVAL ))
    fi
    sleep $IB_INTERVAL
done

# Ensure turbostat is finished
wait $TURBO_PID 2>/dev/null

# --- Cleanup and Tarball ---
echo "Collection complete. Creating tarball..."
TAR_NAME="${LOG_DIR}.tar.gz"
# Check all logs in directory, only include non-empty ones
(cd "$LOG_DIR" && tar -czf "../$TAR_NAME" $(find . -maxdepth 1 -type f -size +0c))

echo "Success! Tarball created: $TAR_NAME"
