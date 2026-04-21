#!/usr/bin/env python3
import sys
import re

def list_to_mask(cpu_range_str):
    """Converts '1-3,288' to kernel hex mask."""
    mask = 0
    try:
        for part in cpu_range_str.split(','):
            if '-' in part:
                start, end = map(int, part.split('-'))
                for i in range(start, end + 1):
                    mask |= (1 << i)
            else:
                mask |= (1 << int(part))
    except ValueError:
        return None

    chunks = []
    # Determine how many 32-bit chunks we need based on the highest bit set
    num_chunks = (mask.bit_length() + 31) // 32
    if num_chunks == 0: num_chunks = 1
    
    for i in range(num_chunks):
        chunk = (mask >> (32 * i)) & 0xffffffff
        chunks.append(f"{chunk:08x}")
    
    chunks.reverse()
    return ",".join(chunks)

def mask_to_list(hex_mask_str):
    """Converts 'ff,00000000' to CPU ranges."""
    # Clean string: remove 0x and whitespace
    clean_mask = hex_mask_str.replace('0x', '').strip()
    chunks = clean_mask.split(',')
    
    full_mask = 0
    for i, chunk in enumerate(reversed(chunks)):
        try:
            full_mask |= int(chunk, 16) << (32 * i)
        except ValueError:
            return None
    
    active_cpus = [i for i in range(full_mask.bit_length()) if (full_mask >> i) & 1]
    
    if not active_cpus:
        return "None"

    ranges = []
    start = active_cpus[0]
    for j in range(1, len(active_cpus) + 1):
        if j == len(active_cpus) or active_cpus[j] != active_cpus[j-1] + 1:
            end = active_cpus[j-1]
            ranges.append(f"{start}-{end}" if start != end else str(start))
            if j < len(active_cpus):
                start = active_cpus[j]
    return ",".join(ranges)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: ./cpumask.py <cpu-list (e.g. 0-4,288) OR hex-mask (e.g. ff,0000000f)>")
        sys.exit(1)

    arg = sys.argv[1].strip()

    # STRICT DETECTION
    # If it contains '-' it MUST be a CPU list.
    # If it contains 'a-f' or is multiple 8-char hex blocks, it's a mask.
    is_hex = False
    if re.search(r'[a-fA-F]', arg) or (',' in arg and len(arg.split(',')[1]) == 8):
        is_hex = True
    if '-' in arg: # Hyphens never appear in hex masks
        is_hex = False

    if is_hex:
        result = mask_to_list(arg)
        if result:
            print(f"Decoding Hex Mask -> CPU List:\n{result}")
        else:
            print("Error: Invalid Hex Mask format.")
    else:
        result = list_to_mask(arg)
        if result:
            print(f"Encoding CPU List -> Hex Mask:\n{result}")
        else:
            print("Error: Invalid CPU List format. Use digits, commas, and hyphens (e.g., 0-5,10).")
