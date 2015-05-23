
This is a quick-and-dirty implementation of the Kubernetes Proxy using iptables rules.

Setup:

    iptables -t nat -I PREROUTING  -j my-dnat
    iptables -t nat -I OUTPUT      -j my-dnat
    iptables -t nat -I POSTROUTING -j my-snat
    /usr/bin/docker run --name kube-iptables-proxy --privileged --net=host mcluseau/kube-iptables-proxy:latest ./watch-apply

