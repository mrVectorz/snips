- cpu isolation
- moving interrupts
- cpu_nohz
- cpu power configuration (cpu idle, cpu wake up)
- ps old data?
- cpu power mgmt (IPI)
CPU waking up from idle
1. PM QoS framework
2. cpuidle_latency_notify is called when latency requirement change.
3. All cores have to be woken up to calculate new C-state
4. Involves sending an IPI (inter-processor interrupt) to all cores to wake-up
5. Preemption is turned off until all CPUs wakeup
- cpu stepping (older cpus had issues when turboing)
- long interrupts can also be caused by long pci wakeup (example wifi)
Can create udev rules
```
$ cat /etc/udev/rules.d/pci_power.rules
SUBSYSTEM=="pci", ATTR{power/control}="on", GOTO="pci_pm_end"
# insert device that can be power mgmt auto
#EXAMPLE SUBSYSTEM=="pci", ATTR{vendor}=="0x000", ATTR{device}=="0x000", ATTR{power/control}="auto", GOTO="pci_pm_end"
LABEL="pci_pm_end"
```

## Troubleshooting
- Mapping the interfac name to the pci slot
```
[core@master-0 ~]$ lspci -D | grep 'Network\|Ethernet'            
0000:02:00.0 Ethernet controller: Broadcom Inc. and subsidiaries NetXtreme BCM5719 Gigabit Ethernet PCIe (rev 01)
0000:02:00.1 Ethernet controller: Broadcom Inc. and subsidiaries NetXtreme BCM5719 Gigabit Ethernet PCIe (rev 01)
0000:02:00.2 Ethernet controller: Broadcom Inc. and subsidiaries NetXtreme BCM5719 Gigabit Ethernet PCIe (rev 01)
0000:02:00.3 Ethernet controller: Broadcom Inc. and subsidiaries NetXtreme BCM5719 Gigabit Ethernet PCIe (rev 01)
0000:04:00.0 Ethernet controller: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection (rev 01)
0000:04:00.1 Ethernet controller: Intel Corporation 82599ES 10-Gigabit SFI/SFP+ Network Connection (rev 01)
0000:05:00.0 Ethernet controller: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ (rev 01)
0000:05:00.1 Ethernet controller: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ (rev 01)
[core@master-0 ~]$ grep PCI_SLOT_NAME /sys/class/net/*/device/uevent
/sys/class/net/eno1/device/uevent:PCI_SLOT_NAME=0000:02:00.0
/sys/class/net/eno2/device/uevent:PCI_SLOT_NAME=0000:02:00.1
/sys/class/net/eno3/device/uevent:PCI_SLOT_NAME=0000:02:00.2
/sys/class/net/eno49/device/uevent:PCI_SLOT_NAME=0000:04:00.0
/sys/class/net/eno4/device/uevent:PCI_SLOT_NAME=0000:02:00.3
/sys/class/net/eno50/device/uevent:PCI_SLOT_NAME=0000:04:00.1
/sys/class/net/ens2f0/device/uevent:PCI_SLOT_NAME=0000:05:00.0
/sys/class/net/ens2f1/device/uevent:PCI_SLOT_NAME=0000:05:00.1
```
- How to identify what is the source of interrupts
- How to isolate CPUs so that an application is the only one running there
- Which IRQ controllers cannot be moved via affinity changes
- Which drivers have no method in which to move thread affinity
- kubectl-trace cmdlet to run system taps
- If changing affinity is returning an IO error, check kernel build options. It requires CONFIG_REGMAP_IRQ (ex raspberrypi issue)
```
$ grep MAP_IRQ /boot/config-$(uname -r) 
CONFIG_REGMAP_IRQ=y
```
- irqbalance does not apply `IRQBALANCE_BANNED_INTERRUPTS` anymore (RHEL 6)
- only properly configured vectors support changing affinity during runtime (IO-APIC)


## References
- TLDR ftracing https://lwn.net/Articles/365835/
- ftrace https://www.kernel.org/doc/html/latest/trace/ftrace.html (`/sys/kernel/debug/tracing/available_filter_functions`)
- kprobes https://www.kernel.org/doc/Documentation/kprobes.txt
- (A)PCI power management https://www.kernel.org/doc/html/latest/power/pci.html
- PM QoS https://github.com/torvalds/linux/blob/master/kernel/power/qos.c
- https://www.kernel.org/doc/html/latest/power/pm_qos_interface.html
