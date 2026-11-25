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
        [
            "geosite:google-gemini",
            "domain:gemini.google.com",
            "domain:aistudio.google.com",
            "domain:generativelanguage.googleapis.com",
            "domain:geminiweb-pa.clients.google.com",
            "domain:geminiweb-pa.clients6.google.com",
            "domain:gemini.gstatic.com",
            "domain:alkalimakersuite-pa.clients6.google.com",
            "domain:waa-pa.clients6.google.com",
            "domain:ogads-pa.clients6.google.com",
            "domain:push.clients6.google.com",
            "domain:people-pa.clients6.google.com",
            "domain:proactivebackend-pa.googleapis.com",
            "domain:robinfrontend-pa.googleapis.com",
            "domain:geller-pa.googleapis.com",
            "domain:aisandbox-pa.googleapis.com",
            "domain:daily-cloudcode-pa.googleapis.com",
            "domain:cloudcode-pa.googleapis.com",
            "domain:antigravity-pa.googleapis.com",
            "domain:content-developerprofiles-pa.googleapis.com",
            "domain:oauth2.googleapis.com",
            "domain:play.googleapis.com",
            "domain:www.googleapis.com",
            "domain:antigravity.google",
            "domain:notebooklm.google.com",
            "domain:labs.google",
            "domain:jules.google.com",
            "domain:ogs.google.com",
            "domain:one.google.com",
            "domain:accounts.google.com",
            "full:www.google.com"
        ] as $domains
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
                    else .domain = $new.domain | .localIP |= reduce $new.localIP[] as $ip (.; if index($ip) then . else . + [$ip] end)
                    end
                else .domain = $new.domain end
              else . end) end
          )
    '
}
