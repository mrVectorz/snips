read -p "Enter rhn-username: " USER
read -s -p "Enter rhn-password: " PASSWORD
echo

CASE=$1

curl --netrc-file <(cat <<<"machine access.redhat.com login $USER password $PASSWORD") "https://access.redhat.com/hydra/rest/cases/${CASE}/attachments/" -o attachements

for i in $(awk '
BEGIN {
  RS=",";
	FS=":";
	names[0]="";
	links[0]="";
	count=0
}{
  if($1 ~ /link/){
		links[count]=$2":"$3
		count++
	}
  if($1 ~ /fileName/){
		names[count]=$2;
	}
} END {
  for(i=0; i < 3; i++){
		print names[i] links[i]
	}
}' attachments); do
  read -r file url <<<$(echo $i | sed 's/\"/ /g')
	echo "Fetching $file $url"
	curl --netrc-file <(cat <<<"machine attachments.access.redhat.com login $USER password $PASSWORD") $url -o $file
done
