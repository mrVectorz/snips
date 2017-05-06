# pretty print xml
echo '<root><foo a="b">lorem</foo><bar value="ipsum" /></root>' | xmllint --format -

# checking rmq queue growth
while :; do rabbitmqctl list_queues 2>&1 | awk '{if ($2 > 0 && $2 ~ /[0-9]+/) print $0}'; printf "%.s-" {0..79}; echo ; sleep 2; done


