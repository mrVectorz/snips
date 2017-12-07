#!/bin/bash

debug=true

bk_dir="${HOME}/mc_backups"
log_file="$bk_dir/log_file.log"
if [ -d $bk_dir ]; then
  mkdir $bk_dir
fi

user="mc_user"
host="$1"
r_home="/home/${user}"

echotee() {
  echo $(date "+%Y-%m-%d %H:%M:%S") $* | tee -a $log_file
}

decho() {
  if $debug; then
    echotee "DEBUG $*"
  fi
}

bk_dirs=$(ssh -vv -i ${HOME}/.ssh/mc_rsa ${user}@${host} "ls ~/ | grep modpack_" 2> >(while read output; do decho $output; done >/dev/null))
decho "Current bk_dirs: $bk_dirs"

for d in $bk_dirs; do
  if ! [ -d $bk_dir/$d ]; then
    echotee "INFO Creating new directory: $d"
    mkdir $bk_dir/$d
  fi
  echotee "INFO Starting rsync of $d"
  rsync -azvrc -e "ssh -i ${HOME}/.ssh/mc_rsa" ${user}@${host}:$r_home/$d/backups/ $bk_dir/$d/ | (
    while read output; do
      echotee "INFO $output"
    done
  )
done

echotee "INFO All backups completed"

