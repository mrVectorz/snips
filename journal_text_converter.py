#!/usr/bin/python
# Author:  Marc Methot
# Version: 2.0

"""
Script to convert output of command:
"journalctl --no-pager --all --boot --output verbose"

To json at which point easier to read and search via jq searches.
This is done simply because sosreports provides it like so.
"""

import re
import json
import os
from sys import argv

class journal_json():
    def __init__(self, journal, json_out="./journal.json"):
        self.json_out = json_out
        self.journal = open(journal, "r")
        self.json_file = open(self.json_out, "w")
    def run(self):
        self.start()
        self.filler()
        self.end()
    def start(self):
        self.json_file.write('{"messages": [\n')
    def end(self):
        self.json_file.seek(-2, os.SEEK_END)
        self.json_file.truncate()
        self.json_file.write("]}")
        self.journal.close()
        self.json_file.close()
    def filler(self):
        __day_filter = re.compile("^[A-z]+.*")
        __field_filter = re.compile("^[\ ]+\w")
        __message = {}
        for line in self.journal:
            if re.match(__day_filter, line):
                time = line.split()[2]
                try:
                    if __message["TIME"] != time:
                        self.to_json(__message)
                        __message = {}
                except KeyError:
                        __message = {"DAY" : line.split()[1], "TIME" : time}
            if re.match(__field_filter, line):
                __message[line.split("=")[0][4:]] = ''.join(
                    [o for o in test.split("=")[1:]])[:-1]
        self.to_json(__message)
    def to_json(self, msg):
        __j_obj = json.dumps(msg)
        self.json_file.write(__j_obj)
        self.json_file.write(",\n")

if __name__ == "__main__":
    j_file = journal_json(argv[1])
    j_file.run()
