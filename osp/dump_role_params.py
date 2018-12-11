#!/usr/bin/env python
# Author: Marc Methot
# Script to dump all role specific paramters in OoO templates

import yaml
import os
import mmap
import itertools
import sys

help_msg="""dump_role_params.py
Is a simply script to dump OoO role specific parameters\n
python dump_role_params.py <path to OoO templates>\n\n
\t--help/-h to see this help message
"""

default_path = "/usr/share/openstack-tripleo-heat-templates/"

if len(sys.argv) >= 2:
    if sys.argv[1] == "--help" or sys.argv[1] == "-h" or len(sys.argv) > 2:
        print(help_msg)
        sys.exit()
    else:
        path = sys.argv[1] if sys.argv[1] else default_path
else:
    path = default_path

paths = [
    "docker/services/",
    "puppet/services/",
    "extraconfig/services/"
]

"""
#python3
def find_files(path):
    files = []
    with os.scandir(path) as it:
        for entry in it:
            if entry.is_file():
                if search_file(entry.path):
                    files.append(entry.path)
    return files
"""
def find_files(path):
    matches = []
    for root, dirs, files in os.walk(path):
        for name in files:
            yaml = os.path.join(root, name)
            if search_file(yaml):
                matches.append(yaml)
    return matches


def search_file(yaml):
    with open(yaml, 'r') as f:
        s = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        if s.find(b'RoleParametersValue') != -1:
            return True
        else:
            return False

def get_role_params(file):
    with open(file, "r") as f:
        data = yaml.load(f)
    params = []
    for para in data['resources']['RoleParametersValue']['properties']['value']['map_replace'][1]['values'].keys():
        params.append(para)
    return params


# Get all files that have "RoleParametersValue"
files = []
for p in paths:
    files.append(find_files(path+p))

files = itertools.chain(*files)
# Get all available params
para = [get_role_params(file) for file in files]
para = list(itertools.chain(*para))
para.sort()

o = ""
for p in para:
    if o != p:
        print(p)
    o = p
