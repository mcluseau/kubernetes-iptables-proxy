#! /usr/bin/ruby
# encoding: utf-8

require 'logger'
$log = Logger.new($stdout)
$log.level = Logger::INFO

$log.info "Initializing..."

require 'json'
require 'shellwords'

class Hash
    # Handle a very common pattern in k8s ;)
    def name
        self["metadata"]["name"]
    end
end

def kube_get(ns, *cmd)
    JSON.load(`./kubectl --namespace=#{ns} -o json get #{cmd.join(" ")}`)
end

dnat_rules = [ ]
snat_rules = [ ]

$log.info "Loading cluster state..."
kube_get("default", "namespace")["items"].map{|ns|ns["metadata"]["name"]}.each do |ns|
    $log.debug "ns #{ns}"

    endpoints = kube_get(ns, "endpoints")["items"].group_by{|endpoint| endpoint.name}

    kube_get(ns, "service")["items"].each do |service|
        $log.debug "  - s #{service["metadata"]["name"]}"
        service_ip = service["spec"]["portalIP"]
        $log.debug "    - service IP: #{service_ip}"

        target_ips = []
        endpoints[service.name].each do |endpoint|
            endpoint["subsets"].each do |subset|
                target_ips += (subset["addresses"]||[]).map{|address| address["IP"]}
            end
        end
        target_ips.sort!

        dnat = "-A my-dnat -d #{service_ip}/32"
        comment = "service #{ns}/#{service.name}"

        service["spec"]["ports"].each do |port|
            port_name = port["name"]
            port_name = nil if port_name.empty?
            protocol = port["protocol"].downcase
            source_port = port["port"]
            target_port = port["targetPort"]
            target_port_match = "-m #{protocol} -p #{protocol} --dport #{source_port}"
            source_port_match = "-m #{protocol} -p #{protocol} --dport #{target_port}"

            $log.debug "      - port: #{source_port} -> #{target_port}"
            target_ips.each_with_index do |target_ip, nth|
                $log.debug "      - to: #{target_ip}"

                rule_comment = "-m comment --comment \"#{comment}#{" #{port_name}" if port_name} (#{source_port} to #{target_ip}:#{target_port})\""
                if nth == target_ips.size-1
                    # last rule should catch the remaining traffic
                    every_nth = ""
                else
                    # every nth matches weirdly, use random for a better distribution
                    #every_nth = " -m statistic --mode nth --packet #{nth} --every #{target_ips.size}"
                    every_nth = " -m statistic --mode random --probability #{1.0/target_ips.size}"
                end

                port_dnat = \
                    "#{dnat} #{source_port_match} #{rule_comment}" +
                    every_nth +
                    " -j DNAT --to-destination #{target_ip}:#{target_port}"

                dnat_rules << port_dnat

                snat_rules << "-A my-snat -d #{target_ip}/32 -j MASQUERADE #{target_port_match} #{rule_comment}"
            end
        end
        # Also reject remaining traffic to the service IP
        dnat = "-A my-dnat -d #{service_ip}/32 -j REJECT"
    end
end

def sync_rules(chain, rules)
    $log.info "Updating chain #{chain} ..."
    # use iptables-restore for transationnal update
    IO.popen("#{ARGV.map{|a|a.shellescape}.join(" ")} iptables-restore --noflush", "w") do |ssh|
        ssh.puts "*nat"
        ssh.puts ":#{chain} -"
        ssh.puts "-F #{chain}"
        rules.each do |wanted_rule|
            ssh.puts wanted_rule
        end
        ssh.puts "COMMIT"
    end
end

sync_rules "my-dnat", dnat_rules
sync_rules "my-snat", snat_rules

$log.info "Finished."
