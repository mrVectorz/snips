#!/usr/bin/python
import sys

def hex_to_comma_list_valid(hex_mask):
    if "," in hex_mask:
        hex_arr = hex_mask.split(",")
        hex_sum = "0x0"
        for h in hex_arr:
            hex_sum = hex(int(str(hex_sum)[2:], 16)+int(h, 16))
        return hex_to_comma_list(hex_sum[2:])
    return hex_to_comma_list(hex_mask)

def hex_to_comma_list(hex_mask):
    binary = bin(int(hex_mask, 16))[2:]
    reversed_binary = binary[::-1]
    i = 0
    output = ""
    for bit in reversed_binary:
        if bit == '1':
            output = output + str(i) + ','
        i = i + 1
    return output[:-1]

def dashes_to_comas(cpus):
    arr = cpus.split(",")
    cpu_arr = []
    i = 0
    for s in arr:
        if "-" in s:
            for n in range(int(arr[i].split("-")[0]),int(arr[i].split("-")[1])+1):
                cpu_arr.append(str(n))
        else:
            cpu_arr.append(s)
        i += 1
    return cpu_arr

def comma_list_to_hex(cpus):
    if "-" in cpus:
        cpu_arr = dashes_to_comas(cpus)
    else:
        cpu_arr = cpus.split(",")
    binary_mask = 0
    for cpu in cpu_arr:
        binary_mask = binary_mask | (1 << int(cpu))
    return format(binary_mask, '02x')

if len(sys.argv) != 2:
    print("Please provide a hex CPU mask or comma separated CPU list")
    sys.exit(2)

user_input = sys.argv[1]

try:
  print(hex_to_comma_list_valid(user_input))
except:
  print(comma_list_to_hex(user_input))
