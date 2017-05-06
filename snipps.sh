# pretty print xml
echo '<root><foo a="b">lorem</foo><bar value="ipsum" /></root>' | xmllint --format -

# checking rmq queue growth
while :; do
  rabbitmqctl list_queues 2>&1 | awk '{if ($2 > 0 && $2 ~ /[0-9]+/) print $0}'
  echo $(printf "%.s-" {0..79})
  sleep 2
done

# self-signed ssl cert one liner
openssl req -x509 -newkey rsa:4096 -keyout Work/test-key.pem -out Work/test-cert.pem -days 3650 -nodes
