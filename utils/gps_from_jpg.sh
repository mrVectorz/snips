#!/bin/bash
# Author: Marc Methot

if [[ $(echo $#) -lt 1 ]]; then
	echo "Requires passing the image full path as an argument"
	echo "Example: gps_from_jpg.sh /home/example/Pictures/test.jpg"
	exit 1
fi
echo "Inspecting file $1"

if ! $(file $1 | grep -q GPS-Data); then
	echo "File has no GPS-Data exit tag"
	exit 2
fi

identify -verbose $1 | awk '
BEGIN {
	Lat="";
	LatRef="";
	Long="";
	LongRef="";
}
{
	if ( $1 ~ /GPSLatitude:/ ){
		gsub(/[,|\/]/, " ", $0);
		Lat=$2/$3+$4/$5/60+$6/$7/3600;
	}
	if ($1 ~ /GPSLatitudeRef:/){
		if ($2 == "S"){
			LatRef="-";
		}
	}
	if ($1 ~ /GPSLongitude:/){
		gsub(/[,|\/]/, " ", $0);
		Long=$2/$3+$4/$5/60+$6/$7/3600;
	}
	if ($1 ~ /GPSLongitudeRef/){
		if ($2 == "W"){
			LongRef="-";
		}
}
}
END {
	#print LatRef""Lat;
	#print LongRef""Long;
	print "https://www.google.com/maps?q=loc:"LatRef""Lat","LongRef""Long
}'

if [[ $? -ne 0 ]]; then
	echo "Make sure to have ImageMagick pkg installed"
	echo 'Example: `rpm -q ImageMagick`'
fi
