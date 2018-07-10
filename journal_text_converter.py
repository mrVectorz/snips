#!/usr/bin/python
# Author:  Marc Methot

# Script to convert output of "journalctl --no-pager --all --boot --output verbose"
# to json at qhich point easier to read and search via jq.

import re
import json
from sys import argv

class json_journal():
    def __init__(self, journal, json_out="./journal.json"):
        self.json_out = json_out
        self.journal = open(journal, "r")
        self.json_file = open(self.json_out, "w")        
    def run(self):
        self.converter()
        self.to_json()
        self.end()
    def end(self):
        self.journal.close()
        self.json_file.close()
    def converter(self):
        __day_filter = re.compile("^[A-z]+.*")
        __day=__time=__msg = ""
        #TODO: Fix the bad workaround. Only reason for this is due to
        #journal trunc
        __unit = "systemd-journald.service"
        self.jdict = {}
        for line in self.journal:
            if re.match(__day_filter, line):
                __nday = line.split()[1]
                if __day != __nday:
                    self.jdict[__nday] = {}
                    __day = __nday
                __time = line.split()[2]
            if "_SYSTEMD_UNIT=" in line:
                __unit = line.split("=")[1][:-1]
            if "MESSAGE=" in line:
                __msg = line.split("=")[1][:-1]
                if __unit not in self.jdict[__nday]:
                    self.jdict[__day][__unit] = []
                self.jdict[__day][__unit].append({"message" : __msg, "time" : __time})
    def to_json(self):
        self.jdict = json.dumps(self.jdict)
        self.json_file.write(self.jdict)

if __name__ == "__main__":
    j_file = json_journal(argv[1])
    j_file.run()
