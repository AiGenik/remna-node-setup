#!/usr/bin/env bash

_selfsteal_caddyfile=/etc/caddy/Caddyfile
_selfsteal_site=/var/www/remna-node-setup
_selfsteal_marker='# Managed by remna-node-setup'
_selfsteal_endpoint=127.0.0.1:8443

_selfsteal_legacy_index_sha256=d0ed18da9879637dfd2fe39b88442cf7c76e46fb45bb5f76f536a1b21e9d2f74

_selfsteal_ipv6_enabled() {
    local flag=/proc/sys/net/ipv6/conf/all/disable_ipv6
    if [[ ${DISABLE_IPV6:-no} == yes ]]; then return 1; fi
    if [[ -r $flag && $(<"$flag") != 0 ]]; then return 1; fi
    return 0
}

_selfsteal_file_sha256() {
    local file=$1 sum
    if command -v sha256sum >/dev/null 2>&1; then
        sum=$(sha256sum -- "$file") || return 1
    else
        sum=$(shasum -a 256 -- "$file") || return 1
    fi
    printf '%s\n' "${sum%% *}"
}

_selfsteal_install_site_files() {
    local asset
    install -d -m 0755 "$_selfsteal_site" || return 1
    if [[ ! -f $_selfsteal_site/index.html ]] ||
        [[ $(_selfsteal_file_sha256 "$_selfsteal_site/index.html" 2>/dev/null) == "$_selfsteal_legacy_index_sha256" ]]; then
        install -m 0644 "$PROJECT_DIR/templates/index.html" "$_selfsteal_site/index.html" || return 1
    fi
    for asset in robots.txt favicon.svg; do
        if [[ -r $PROJECT_DIR/templates/$asset && ! -e $_selfsteal_site/$asset && ! -L $_selfsteal_site/$asset ]]; then
            install -m 0644 "$PROJECT_DIR/templates/$asset" "$_selfsteal_site/$asset" || return 1
        fi
    done
}

_selfsteal_caddy_owned_config() {
    [[ -f $_selfsteal_caddyfile && ! -L $_selfsteal_caddyfile ]] &&
        grep -Fxq "$_selfsteal_marker" "$_selfsteal_caddyfile"
}

_selfsteal_validate_domain() {
    local domain=${NODE_DOMAIN%.} result=0
    domain=${domain,,}
    if ! valid_domain "$domain"; then
        fail 'Введите имя домена, например node.example.com.'
        return 1
    fi
    timeout 12s python3 "$PROJECT_DIR/lib/selfsteal-dns.py" "$domain" "${1:-quiet}" || result=$?
    if (( result == 124 )); then
        fail "DNS для $domain не ответил за 12 секунд. Проверьте резолвер VPS."
        return 1
    fi
    return "$result"
}

_selfsteal_caddy_preflight() {
    if [[ -e $_selfsteal_caddyfile || -L $_selfsteal_caddyfile ]] && ! _selfsteal_caddy_owned_config; then
        fail "Найдена сторонняя конфигурация Caddy. Для self-steal нужен отдельный VPS."
        return 1
    fi
}

selfsteal_preflight() {
    local port listening service pid
    local -a ports=(80 8443) owned_units=() own_listeners=()
    _selfsteal_validate_domain quiet || return 1
    if [[ $SELFSTEAL_SERVER == caddy ]]; then
        _selfsteal_caddy_preflight || return 1
        ports+=(2019)
    fi
    if [[ $SELFSTEAL_SERVER == nginx ]] || _selfsteal_nginx_owned_config; then
        nginx_selfsteal_preflight || return 1
    fi
    if _selfsteal_caddy_owned_config; then owned_units+=(caddy.service); fi
    if _selfsteal_nginx_owned_config; then owned_units+=(nginx.service); fi
    if [[ -L $_selfsteal_site || -L $_selfsteal_site/index.html ||
        -L $_selfsteal_site/robots.txt || -L $_selfsteal_site/favicon.svg ||
        ( -e $_selfsteal_site/index.html && ${#owned_units[@]} == 0 ) ]]; then
        fail "Каталог страницы $_selfsteal_site уже используется."
        return 1
    fi
    for service in "${owned_units[@]}"; do
        pid=$(systemctl show -p MainPID --value "$service") || return 1
        if [[ $pid =~ ^[1-9][0-9]*$ ]]; then own_listeners+=(-e "pid=$pid,"); fi
    done
    for port in "${ports[@]}"; do
        listening=$(ss -H -ltnp "sport = :$port") || return 1
        if [[ -n $listening ]] && {
            [[ ${#own_listeners[@]} == 0 ]] ||
                grep -Fv "${own_listeners[@]}" <<<"$listening" >/dev/null
        }; then
            fail "TCP-порт $port для self-steal уже занят другим сервисом."
            return 1
        fi
    done
    return 0
}

selfsteal_public_port() {
    local entry
    for entry in ${VPN_PORTS-}; do
        if [[ $entry == */tcp ]] && valid_port "${entry%/*}"; then
            printf '%s\n' "${entry%/*}"
            return
        fi
    done
    printf '443\n'
}

selfsteal_redirect_host() {
    local port
    port=$(selfsteal_public_port) || return
    printf '%s' "${NODE_DOMAIN%.}"
    if [[ $port != 443 ]]; then printf ':%s' "$port"; fi
}

_selfsteal_render_config() {
    local target=$1 domain=${NODE_DOMAIN%.} redirect_host
    redirect_host=$(selfsteal_redirect_host) || return
    cat >"$target" <<EOF_CADDY
$_selfsteal_marker
{
	auto_https disable_redirects
	servers {
		protocols h1 h2
	}
}

http://$domain {
	header -Server
	redir https://${redirect_host}{uri} 308
}

https://$domain:8443 {
	bind 127.0.0.1
	tls {
		issuer acme {
			disable_tlsalpn_challenge
		}
	}
	header {
		-Server
		X-Frame-Options "SAMEORIGIN"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
	}
	root * $_selfsteal_site
	file_server
}
EOF_CADDY
}

_selfsteal_verify_https() {
    local domain=${NODE_DOMAIN%.}
    curl --fail --silent --noproxy '*' --max-time 3 \
        --resolve "$domain:8443:127.0.0.1" "https://$domain:8443/" >/dev/null
}

_selfsteal_caddy_verify() {
    _selfsteal_caddy_owned_config && systemctl is-active --quiet caddy.service && _selfsteal_verify_https
}

_selfsteal_caddy_activate_config() {
    local stage
    stage=$(mktemp /etc/caddy/.remna-setup.XXXXXX) || return 1
    if ! _selfsteal_render_config "$stage" ||
        ! caddy validate --adapter caddyfile --config "$stage" ||
        ! chmod 0644 "$stage" ||
        ! mv -f -- "$stage" "$_selfsteal_caddyfile"; then
        rm -f -- "$stage"
        return 1
    fi
    systemctl enable --now caddy.service || return 1
    systemctl reload caddy.service
}

_selfsteal_caddy_apply() {
    local attempt
    apt_install_current caddy || return 1
    install -d -m 0755 /etc/caddy || return 1
    _selfsteal_install_site_files || return 1
    _selfsteal_caddy_activate_config || return 1
    info "Caddy получает сертификат для $NODE_DOMAIN через порт 80."
    for ((attempt = 0; attempt < 35; attempt++)); do
        if _selfsteal_caddy_verify; then
            info "Self-steal: локальная HTTPS-страница отвечает с доверенным сертификатом."
            return 0
        fi
        sleep 2
    done
    fail "Сертификат Caddy не готов. Проверьте DNS, доступность TCP 80 и журнал caddy.service."
}

selfsteal_apply() {
    selfsteal_preflight || return 1
    case "$SELFSTEAL_SERVER" in
        caddy)
            if _selfsteal_nginx_owned_config; then nginx_selfsteal_stop || return; fi
            _selfsteal_caddy_apply
            ;;
        nginx)
            if _selfsteal_caddy_owned_config; then systemctl disable --now caddy.service || return; fi
            nginx_selfsteal_apply
            ;;
        *) fail 'Выберите Caddy или Nginx.' ;;
    esac
}

selfsteal_verify() {
    case "$SELFSTEAL_SERVER" in
        caddy) _selfsteal_caddy_verify ;;
        nginx) nginx_selfsteal_verify ;;
        *) return 1 ;;
    esac
}

selfsteal_refresh_redirect() {
    local domain=${NODE_DOMAIN%.} cert_dir
    cert_dir=$STATE_DIR/nginx-certbot/config/live/$domain
    case "$SELFSTEAL_SERVER" in
        caddy) _selfsteal_caddy_owned_config && _selfsteal_caddy_activate_config ;;
        nginx)
            if _selfsteal_nginx_owned_config; then
                if [[ -s $cert_dir/fullchain.pem && -s $cert_dir/privkey.pem ]]; then
                    _nginx_selfsteal_activate_config tls
                else
                    _nginx_selfsteal_activate_config http
                fi
            fi
            ;;
    esac
}

selfsteal_status() {
    local name=Caddy
    if [[ $SELFSTEAL_SERVER == nginx ]]; then name=Nginx; fi
    if ! _selfsteal_caddy_owned_config && ! _selfsteal_nginx_owned_config; then
        fail 'Отсутствует управляемый конфиг self-steal.'
        return 1
    fi
    if selfsteal_verify; then
        info "Self-steal: $name отвечает на $_selfsteal_endpoint по HTTPS."
    else
        warn "Self-steal: $name или доверенный сертификат для $NODE_DOMAIN недоступен."
        return 1
    fi
    if [[ $SELFSTEAL_SERVER == nginx ]] && ! nginx_selfsteal_renewal_active; then
        fail 'Таймер продления сертификата Nginx не работает.'
        return 1
    fi
}

selfsteal_panel_help() {
    local port
    port=$(selfsteal_public_port) || return
    cat <<EOF_PANEL
  VLESS REALITY и Host · $port/tcp
  realitySettings · target $_selfsteal_endpoint · serverNames ["${NODE_DOMAIN%.}"] · xver 0
EOF_PANEL
}
