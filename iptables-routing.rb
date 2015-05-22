#! /usr/bin/ruby
# encoding: utf-8

require 'json'
require 'shellwords'

def kube_get(ns, *cmd)
    JSON.load(`kubectl --namespace=#{ns} -o json get #{cmd.join(" ")}`)
end

dnat_rules = [ ]
snat_rules = [ ]

kube_get("default", "namespace")["items"].map{|ns|ns["metadata"]["name"]}.sort.each do |ns|
    puts "ns #{ns}"

    kube_get(ns, "service")["items"].each do |service|
        puts "  - s #{service["metadata"]["name"]}"
        service_ip = service["spec"]["portalIP"]
        #puts "    - service IP: #{service_ip}"

        selector = service["spec"]["selector"]
        next unless selector

        pods = kube_get(ns, "pod","-l",selector.map{|k,v|"#{k}=#{v}"}.join(","))["items"]
        next if pods.empty?

        target_ips = pods.map do |pod|
            pod["status"]["podIP"]
        end
        target_ips.sort!

        # TODO support load-balancing
        next if target_ips.size > 1

        dnat = "-A my-dnat -d #{service_ip}/32"
        comment = "service #{ns}/#{service["metadata"]["name"]}"

        target_ips.each do |target_ip|
            snat_rules << "-A my-snat -d #{target_ip}/32 -j MASQUERADE"

            service["spec"]["ports"].each do |port|
                protocol = port["protocol"]
                source_port = port["port"]
                target_port = port["targetPort"]

                port_name = port["name"]
                port_name = nil if port_name.empty?

                port_comment = "#{comment}#{" #{port_name}" if port_name} (#{source_port} to #{target_port})"

                port_dnat = \
                    "#{dnat}" \
                    " -p #{protocol.downcase} --dport #{source_port}" \
                    " -m comment --comment #{port_comment.shellescape}" \
                    " -j DNAT" \
                    " --to-destination '#{target_ip}:#{target_port}'"

                dnat_rules << port_dnat
            end
        end
    end
end

def sync_rules(chain, rules)
    existing_rules = `ssh ceph-2.isi iptables -t nat -w -S #{chain}`.strip
    existing_rules = existing_rules.empty? ? [] : existing_rules.split("\n")

    IO.popen("ssh ceph-2.isi", "w") do |ssh|
        rules.each do |wanted_rule|
            next if existing_rules.member? wanted_rule
            puts "+ #{wanted_rule}"
            ssh.puts "iptables -t nat -w #{wanted_rule}"
            ssh.flush
        end
        existing_rules.each do |existing_rule|
            next if existing_rule =~ /^-N/
            next if rules.member? existing_rule
            puts "- #{existing_rule}"
            ssh.puts "iptables -t nat -w #{existing_rule.sub("-A","-D")}"
            ssh.flush
        end
    end
end

sync_rules "my-dnat", dnat_rules
sync_rules "my-snat", snat_rules

