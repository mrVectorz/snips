#!/bin/bash

# Update all the things
yum update -y
yum upgrade -y

# Install usefull packages
pkgs=(
  'vim'
  'sysstat'
  'bind-utils'
  'java-1.8.0-openjdk'
  'java-1.8.0-openjdk-debug'
  'java-1.8.0-openjdk-devel'
  'java-1.8.0-openjdk-devel-debug'
  'unzip'
  'screen'
  'rsync'
)
yum install ${pkgs[@]} -y

### Some sense of security ###
systemctl enable firewalld
systemctl start firewalld

# Bell and MTS
CIDRs="76.64.0.0/13 76.65.156.0/22 206.45.176.0/22 142.161.0.0/16"
# ssh and mc_server
ports="22 1987"

# Adding the rules
for ip in $CIDRs; do
  for port in $ports; do
    echo "Adding firewall rule"
    firewall-cmd --permanent --zone public --add-rich-rule 'rule family="ipv4" source address="'$ip'" port protocol="tcp" port="'$port'" accept'
  done
done

# Removal of the services
for i in $(firewall-cmd --zone public --list-services); do
  echo "Removing firewalld service $i"
  firewall-cmd --permanent --zone public --remove-service $i
done

# Reloading the table
firewall-cmd --reload

### system basics ###
sysctl -w vm.swappiness=0

systemctl disable avahi-daemon
systemctl stop avahi-daemon

# ssh
if ! [ -d ~/.ssh ]; then
  mkdir ~/.ssh -m 700
fi
echo "Copy your pub ssh authkey now:"
read ssh_key
echo $ssh_key > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys 
restorecon -Rv ~/.ssh 
# backup copy
cp /etc/ssh/sshd_config ~/sshd_config.backup
sed -i 's/\(PasswordAuthentication\) yes/\1 no/' /etc/ssh/sshd_config
systemctl restart sshd

### MC SETUP ###
useradd -m mc_user -p Completly_1_Unsafe_2_Password
if ! [ -d /home/mc_user/.ssh ]; then
  mkdir /home/mc_user/.ssh -m 700
fi

mc_key="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDCN33zHY4pIpzZffm+0fGCmKjYQJXGYxBk/JmZVEDv7KR3Ne+fL7scZWD4Slk0wMAqHA2gpJTPrAFExSDvSoBqeqs+1U12Pw5M4AqGIgLGwHFetGlDG0OFDPYR97/u0rowCszx1W4aOllZDEqJvOdvn4DvXmrOgMF4vVRgysCQVVbGHvC+7+EvXqipiGPuzWUbyX/8YHQFVkb4tghIpTBRBLxgy3SnQfoq0A2XRvojwZLt7P2oD9/Qr5eBvghBgl3ICXDGKjt6v6idAw9d/PPogvi1apiXooWxB1pUTPF94OVq1v4fGb7AoB2acCk7XXhN50LN3W1UlZIDweqnCeYZ"
echo $mc_key > /home/mc_user/.ssh/authorized_keys
chmod 600 /home/mc_user/.ssh/authorized_keys
chown -R mc_user. /home/mc_user/.ssh

