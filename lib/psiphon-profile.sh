#!/usr/bin/env bash

psiphon_profile() {
    local requested=${1-} default address prefix outbound
    outbound=$(psiphon_outbound) || return
    if [[ -z $requested ]]; then
        default=$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{ for (i=1; i<NF; i++) if ($i == "src") { print $(i+1); exit } }') || default=
        if [[ $UI_INTERACTIVE == yes ]]; then
            requested=$(prompt '  IP этой ноды →' "$default") || return
        else
            requested=$default
        fi
    fi
    address=$(normalize_ips "$requested") || return
    if [[ -z $address || $address == *' '* ]]; then
        fail 'Укажите один IP ноды для правила в общем профиле.'
        return 1
    fi
    prefix=32
    if [[ $address == *:* ]]; then prefix=128; fi
    jq -n --arg local_ip "$address/$prefix" --argjson socks "$outbound" '
        ["full:gemini.google.com", "full:aistudio.google.com",
         "full:generativelanguage.googleapis.com", "full:geminiweb-pa.clients.google.com",
         "full:geminiweb-pa.clients6.google.com", "full:gemini.gstatic.com"] as $domains
        | {
            outbounds: [
                $socks,
                {tag: "psiphon-quic-block", protocol: "blackhole"}
            ],
            routing: {
                rules: [
                    {type: "field", ruleTag: "gemini-psiphon-block-quic", localIP: [$local_ip],
                     domain: $domains, network: "udp", port: "443", outboundTag: "psiphon-quic-block"},
                    {type: "field", ruleTag: "gemini-psiphon-tcp", localIP: [$local_ip],
                     domain: $domains, network: "tcp", outboundTag: $socks.tag}
                ]
            }
        }
    '
}
