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

psiphon_profile_merge() {
    local fragment
    fragment=$(psiphon_profile "${1-}") || return
    jq -e --argjson fragment "$fragment" '
        def matching($new):
            .ruleTag == $new.ruleTag or
            (.outboundTag == $new.outboundTag and .network == $new.network and
             ((.domain // []) | any(test("gemini|generativelanguage"; "i"))));

        if type != "object" or (.outbounds | type) != "array" or
            ((.routing.rules // []) | type) != "array"
        then error("Передайте JSON профиля Remnawave с массивом outbounds.") else . end
        | reduce $fragment.outbounds[] as $new (.;
            ([.outbounds[] | select(.tag == $new.tag)]) as $found
            | if ($found | length) == 0 then .outbounds += [$new]
              elif $found != [$new] and (
                ($found | length) > 1 or $found[0].protocol != $new.protocol or
                ($new.protocol == "socks" and
                 ($found[0].settings.address != $new.settings.address or $found[0].settings.port != $new.settings.port))
              ) then error("Конфликт outbound " + $new.tag + ". Проверьте общий профиль.")
              else . end
          )
        | .routing.rules = reduce ($fragment.routing.rules | reverse[]) as $new ((.routing.rules // []);
            ([.[] | select(matching($new))] | length) as $count
            | if $count == 0 then [$new] + .
              elif $count > 1 then error("В профиле несколько правил " + $new.ruleTag + ".")
              else map(if matching($new) then
                if .outboundTag != $new.outboundTag or .network != $new.network or
                   ($new.network == "udp" and (.port | tostring) != ($new.port | tostring))
                    then error("Конфликт правила " + $new.ruleTag + ".")
                elif has("localIP") then
                    if (.localIP | type) != "array" then error("Ожидался массив localIP.")
                    else .localIP |= reduce $new.localIP[] as $ip (.; if index($ip) then . else . + [$ip] end)
                    end
                else . end
              else . end) end
          )
    '
}
