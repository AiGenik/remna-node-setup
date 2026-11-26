#!/usr/bin/env bash

psiphon_profile() {
    local requested=${1-} default='all' address='' prefix outbound local_ip_json='null'
    outbound=$(psiphon_outbound) || return
    if [[ -z $requested ]]; then
        default=$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{ for (i=1; i<NF; i++) if ($i == "src") { print $(i+1); exit } }') || default=
        if [[ $UI_INTERACTIVE == yes ]]; then
            info '  Введите «all», чтобы правило работало на всех нодах (включая новые),'
            info "  либо IP конкретной ноды${default:+ (текущий: $default)}."
            requested=$(prompt '  Ноды для шаблона [all] →' 'all') || return
        else
            requested=all
        fi
    fi
    if [[ ${requested,,} != all ]]; then
        address=$(normalize_ips "$requested") || return
        if [[ -z $address || $address == *' '* ]]; then
            fail 'Укажите «all» или один IP ноды для правила в общем профиле.'
            return 1
        fi
        prefix=32
        if [[ $address == *:* ]]; then prefix=128; fi
        local_ip_json=$(jq -Rn --arg ip "$address/$prefix" '[$ip]')
    fi
    jq -n --argjson local_ip "$local_ip_json" --argjson socks "$outbound" '
        [
            "geosite:youtube",
            "domain:youtube.com",
            "domain:googlevideo.com",
            "domain:ytimg.com",
            "domain:youtu.be",
            "domain:yt.be",
            "domain:youtube-nocookie.com",
            "domain:yt3.ggpht.com"
        ] as $youtube_domains
        | [
            "geosite:google-gemini",
            "domain:gemini.google.com",
            "domain:aistudio.google.com",
            "domain:generativelanguage.googleapis.com",
            "domain:geminiweb-pa.clients.google.com",
            "domain:geminiweb-pa.clients6.google.com",
            "domain:gemini.gstatic.com",
            "domain:alkalimakersuite-pa.clients6.google.com",
            "domain:waa-pa.clients6.google.com",
            "domain:proactivebackend-pa.googleapis.com",
            "domain:robinfrontend-pa.googleapis.com",
            "domain:geller-pa.googleapis.com",
            "domain:aisandbox-pa.googleapis.com",
            "domain:daily-cloudcode-pa.googleapis.com",
            "domain:cloudcode-pa.googleapis.com",
            "domain:antigravity-pa.googleapis.com",
            "domain:content-developerprofiles-pa.googleapis.com",
            "domain:antigravity.google",
            "domain:notebooklm.google.com",
            "domain:labs.google",
            "domain:jules.google.com"
        ] as $domains
        | ({type: "field", ruleTag: "youtube-direct", domain: $youtube_domains, outboundTag: "DIRECT"}) as $yt_rule
        | ({type: "field", ruleTag: "gemini-psiphon-block-quic", domain: $domains,
            network: "udp", port: "443", outboundTag: "psiphon-quic-block"}
           + (if $local_ip != null then {localIP: $local_ip} else {} end)) as $quic_rule
        | ({type: "field", ruleTag: "gemini-psiphon-tcp", domain: $domains,
            network: "tcp", outboundTag: $socks.tag}
           + (if $local_ip != null then {localIP: $local_ip} else {} end)) as $tcp_rule
        | {
            outbounds: [
                {tag: "DIRECT", protocol: "freedom"},
                $socks,
                {tag: "psiphon-quic-block", protocol: "blackhole"}
            ],
            routing: {
                rules: [$yt_rule, $quic_rule, $tcp_rule]
            }
        }
    '
}

psiphon_profile_merge() {
    local fragment
    fragment=$(psiphon_profile "${1-}") || return
    jq -e --argjson fragment "$fragment" '
        def direct_tag:
            ([.outbounds[] | select((.tag | ascii_downcase) == "direct") | .tag] | first) // "DIRECT";

        def matching($new):
            .ruleTag == $new.ruleTag or
            ($new.ruleTag != "youtube-direct" and .outboundTag == $new.outboundTag and .network == $new.network and
             ((.domain // []) | any(test("gemini|generativelanguage"; "i"))));

        if type != "object" or (.outbounds | type) != "array" or
            ((.routing.rules // []) | type) != "array"
        then error("Передайте JSON профиля Remnawave с массивом outbounds.") else . end
        | direct_tag as $dtag
        | ($fragment.outbounds | map(if .tag == "DIRECT" then .tag = $dtag else . end)) as $outbounds
        | ($fragment.routing.rules | map(if .ruleTag == "youtube-direct" then .outboundTag = $dtag else . end)) as $rules
        | reduce $outbounds[] as $new (.;
            ([.outbounds[] | select(.tag == $new.tag)]) as $found
            | if ($found | length) == 0 then .outbounds += [$new]
              elif $new.tag == $dtag then .
              elif $found != [$new] and (
                ($found | length) > 1 or $found[0].protocol != $new.protocol or
                ($new.protocol == "socks" and
                 ($found[0].settings.address != $new.settings.address or $found[0].settings.port != $new.settings.port))
              ) then error("Конфликт outbound " + $new.tag + ". Проверьте общий профиль.")
              else . end
          )
        | .routing.rules = reduce ($rules | reverse[]) as $new ((.routing.rules // []);
            ([.[] | select(matching($new))] | length) as $count
            | if $count == 0 then [$new] + .
              elif $count > 1 then error("В профиле несколько правил " + $new.ruleTag + ".")
              else map(if matching($new) then
                if .outboundTag != $new.outboundTag or ((.network // "") != ($new.network // "")) or
                   ($new.network == "udp" and (.port | tostring) != ($new.port | tostring))
                    then error("Конфликт правила " + $new.ruleTag + ".")
                elif ($new | has("localIP") | not) then
                    del(.localIP) | .domain = $new.domain
                elif has("localIP") then
                    if (.localIP | type) != "array" then error("Ожидался массив localIP.")
                    else .domain = $new.domain | .localIP |= reduce $new.localIP[] as $ip (.; if index($ip) then . else . + [$ip] end)
                    end
                else .domain = $new.domain end
              else . end) end
          )
    '
}
