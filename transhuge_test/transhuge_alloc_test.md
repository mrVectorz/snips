## Testing mem THP Allocation
Testing THP allocation with different `/sys/kernel/mm/transparent_hugepage/enabled` settings.

### Results
Set to `always`
```
# echo always > /sys/kernel/mm/transparent_hugepage/enabled
# cat /sys/kernel/mm/transparent_hugepage/enabled
[always] madvise never
# #RE-RUNING SCRIPT
# awk  '/AnonHugePages/ { if($2>4){print FILENAME " " $0; system("ps -fp " gensub(/.*\/([0-9]+).*/, "\\1", "g", FILENAME))}}' /proc/$(pgrep "hugepage_allo")/smaps
/proc/3770432/smaps AnonHugePages:     10240 kB
UID          PID    PPID  C STIME TTY          TIME CMD
mmethot  3770432  281142  0 14:36 pts/2    00:00:00 ./hugepage_alloc_test
/proc/3770432/smaps AnonHugePages:     10240 kB
UID          PID    PPID  C STIME TTY          TIME CMD
mmethot  3770432  281142  0 14:36 pts/2    00:00:00 ./hugepage_alloc_test
```

Set to `madvise`
```
# echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
# cat /sys/kernel/mm/transparent_hugepage/enabled
always [madvise] never
# #RE-RUNING SCRIPT
# awk  '/AnonHugePages/ { if($2>4){print FILENAME " " $0; system("ps -fp " gensub(/.*\/([0-9]+).*/, "\\1", "g", FILENAME))}}' /proc/$(pgrep "hugepage_allo")/smaps
/proc/3770501/smaps AnonHugePages:     10240 kB
UID          PID    PPID  C STIME TTY          TIME CMD
mmethot  3770501  281142  0 14:38 pts/2    00:00:00 ./hugepage_alloc_test
```

Set to `never`
```
# cat /sys/kernel/mm/transparent_hugepage/enabled
always madvise [never]
# #RE-RUNING SCRIPT
# awk  '/AnonHugePages/ { if($2>4){print FILENAME " " $0; system("ps -fp " gensub(/.*\/([0-9]+).*/, "\\1", "g", FILENAME))}}' /proc/$(pgrep "hugepage_allo")/smaps
root@rhel10:~#
```
