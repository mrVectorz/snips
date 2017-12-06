#!/bin/bash
echo "What modpock do you wish to setup?"
echo "Example: ftb-infinity-evolved-skyblock"
read mod_pack

version=$(curl -s https://www.feed-the-beast.com/projects/${mod_pack}/files | awk '/Server Pack/ {print gensub(/^.*files\/([0-9]+).*$/, "\\1", "g", $2)}')
s_version=$(curl -s https://www.feed-the-beast.com/projects/${mod_pack}/files/${version} | awk '/server-pack-download/ {print gensub(/.*files\/([0-9]+).*/, "\\1", "g", $0)}')
mkdir modpack_${mod_pack}
cd modpack_${mod_pack}/
wget "https://www.feed-the-beast.com/projects/${mod_pack}/files/${s_version}/download"
unzip download
rm -f download

sed -i 's/\(eula=\)false/\1true/' eula.txt

cat << EOF > settings-local.sh
export JAVACMD="java"
export MIN_RAM="1g"        # -Xms
export MAX_RAM="6G"       # -Xmx
export PERMGEN_SIZE="1g"   # -XX:PermSize
export JAVA_PARAMETERS="-XX:+UseParNewGC -XX:+CMSIncrementalPacing -XX:+CMSClassUnloadingEnabled -XX:ParallelGCThreads=2 -XX:MinHeapFreeRatio=5 -XX:MaxHeapFreeRatio=10"
EOF
cp settings-local.sh settings.sh

cat << EOF > server.properties
max-tick-time=60000
generator-settings=
allow-nether=true
force-gamemode=false
gamemode=0
enable-query=false
player-idle-timeout=0
difficulty=3
spawn-monsters=true
op-permission-level=4
announce-player-achievements=true
pvp=true
snooper-enabled=true
level-type=DEFAULT
hardcore=false
enable-command-block=false
max-players=20
network-compression-threshold=256
resource-pack-sha1=
max-world-size=29999984
server-port=1987
server-ip=
spawn-npcs=true
allow-flight=false
level-name=world
view-distance=10
resource-pack=
spawn-animals=true
white-list=true
generate-structures=true
online-mode=true
max-build-height=256
level-seed=
use-native-transport=true
motd=covfefe
enable-rcon=false
EOF

cat << EOF > whitelist.json
[
  {
    "uuid": "bc8ef9c9-953e-462c-a049-7a7ed92a3033",
    "name": "CORYOLDFORD"
  },
  {
    "uuid": "2162b8a3-af4c-44de-a944-c8e8cb3a1967",
    "name": "root_account"
  }
]
EOF

echo done
