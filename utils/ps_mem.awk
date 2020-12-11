#!/bin/awk -f
BEGIN {
  total=0
  a="1 2 3 4 5"
  b[0]=""
  b[1]=""
}
{
  split(a,i," ")
  if ($5 > i[5] && $5 ~ /[0-9]+/) { b[2]=b[1]; b[1]=a; b[0]=$0; a=$0 }
  total=total+$5
}
END {
  print "Top 3 Mem gougers:"
  for (x in b) print b[x]
  print "\nTotal Mem Used: " total
}
