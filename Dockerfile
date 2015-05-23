from ruby

run apt-get update && apt-get install -y iptables && apt-get clean

add . /

cmd while sleep 60; do ruby /iptables-routing.rb; done
