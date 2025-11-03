{
    # Check if the first column ($1) contains "rook-ceph-mon"
    if ($1 ~ /rook-ceph-mon/) {
        mon_nodes[$7] = 1  # Store the node name (column 7) in an array
    }

    # Check if the first column ($1) contains "rook-ceph-osd"
    if ($1 ~ /rook-ceph-osd/) {
        osd_nodes[$7]++  # Increment the count for that node name (column 7)
    }
}
END {
    print "Ceph Monitor (mon) Pods Location"
    print "---------------------------------------"
    for (node in mon_nodes) {
        print node
    }
    print ""
    print "Ceph OSD Pods & Count per Node"
    print "---------------------------------------"
    for (node in osd_nodes) {
        print node ": " osd_nodes[node] " OSDs"
    }
}
