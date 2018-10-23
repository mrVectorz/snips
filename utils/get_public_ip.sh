#!/bin/bash
# Author: Marc Methot
result=""
function check_result() {
  if [[ ! -z $result ]] ; then
    echo $result
    exit 0
  fi
}

result=$(curl -k -s https://www.privateinternetaccess.com/pages/whats-my-ip/ |
  awk '/Your IP Address/ {
    print gensub(/.*: ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)<.*/, "\\1", "g", $0)}')
check_result

reuslt=$(curl -k -s https://whatsmyip.com/ |
  awk '/h1 boldAndShado/ {
    print gensub(/.*>([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)<.*/, "\\1", "g", $0)}')
check_result

# has a 5 day limit checkup
result=$(curl -s -L -k -H 'Referer: https://www.google.ca/' -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36' https://www.whatismyip.com/ |
  awk '/Your Public IPv4/ {
    print gensub(/.*>([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)<.*/, "\\1", "g", $0)}')
check_result
