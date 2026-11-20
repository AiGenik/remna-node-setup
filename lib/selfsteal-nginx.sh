#!/usr/bin/env bash
# _selfsteal_marker and _selfsteal_site are defined by lib/selfsteal.sh.
# shellcheck disable=SC2154

_nginx_selfsteal_config=/etc/nginx/conf.d/remna-node-setup.conf
_nginx_selfsteal_renewal=remna-node-setup-certbot

_selfsteal_nginx_owned_config() {
    [[ -f $_nginx_selfsteal_config && ! -L $_nginx_selfsteal_config ]] &&
        grep -Fxq -- "$_selfsteal_marker" "$_nginx_selfsteal_config"
}

_nginx_selfsteal_stock_file() {
    local path=$1 expected actual
    [[ -f $path && ! -L $path ]] || return 1
    expected=$(dpkg-query -W -f='${Conffiles}' nginx-common 2>/dev/null |
        awk -v path="$path" '$1 == path { print $2 }') || return 1
    [[ $expected =~ ^[0-9a-f]{32}$ ]] || return 1
    actual=$(md5sum -- "$path") || return 1
    [[ ${actual%% *} == "$expected" ]]
}

nginx_selfsteal_preflight() {
    local path
    if [[ -e $_nginx_selfsteal_config || -L $_nginx_selfsteal_config ]] &&
        ! _selfsteal_nginx_owned_config; then
        fail "Найден чужой конфиг $_nginx_selfsteal_config."
        return 1
    fi
    for path in /etc/systemd/system/"$_nginx_selfsteal_renewal".{service,timer}; do
        if [[ -L $path ]] || [[ -e $path && ! -f $path ]] ||
            { [[ -f $path ]] && ! grep -Fxq -- "$_selfsteal_marker" "$path"; }; then
            fail "Найден чужой сервис $path."
            return 1
        fi
    done
    if [[ -L /etc/nginx/conf.d || -L "$_selfsteal_site/.well-known" ||
        -L "$_selfsteal_site/.well-known/acme-challenge" ]]; then
        fail 'Проверьте каталоги конфигурации Nginx и HTTP-проверки.'
        return 1
    fi
    if [[ -e /etc/nginx/nginx.conf || -L /etc/nginx/nginx.conf ]] &&
        ! _nginx_selfsteal_stock_file /etc/nginx/nginx.conf; then
        fail 'Найден изменённый nginx.conf. Для self-steal нужен отдельный VPS.'
        return 1
    fi
    for path in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
        if [[ $path == "$_nginx_selfsteal_config" || ( ! -e $path && ! -L $path ) ]]; then
            continue
        fi
        if [[ $path == /etc/nginx/sites-enabled/default && -L $path &&
            $(readlink -f -- "$path") == /etc/nginx/sites-available/default ]] &&
            _nginx_selfsteal_stock_file /etc/nginx/sites-available/default; then
            continue
        fi
        fail "Найден чужой сайт Nginx в $path."
        return 1
    done
    return 0
}

_nginx_selfsteal_render_config() {
    local mode=$1 domain=${NODE_DOMAIN%.} redirect_host
    local cert_dir=$STATE_DIR/nginx-certbot/config/live/$domain
    redirect_host=$(selfsteal_redirect_host) || return
    cat <<EOF_NGINX
$_selfsteal_marker
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root "$_selfsteal_site";
        try_files \$uri =404;
    }

    location / {
        return 308 https://$redirect_host\$request_uri;
    }
}
EOF_NGINX
    if [[ $mode == tls ]]; then
        cat <<EOF_NGINX

server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $domain;

    ssl_certificate "$cert_dir/fullchain.pem";
    ssl_certificate_key "$cert_dir/privkey.pem";
    ssl_protocols TLSv1.2 TLSv1.3;

    root "$_selfsteal_site";
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF_NGINX
    fi
}

_nginx_selfsteal_activate_config() {
    local stage
    stage=$(mktemp /etc/nginx/conf.d/.remna-setup.XXXXXX) || return 1
    if ! _nginx_selfsteal_render_config "$1" > "$stage" ||
        ! chmod 0644 "$stage" || ! mv -f -- "$stage" "$_nginx_selfsteal_config"; then
        rm -f -- "$stage"
        return 1
    fi
    nginx -t && systemctl enable --now nginx.service && systemctl reload nginx.service
}

_nginx_selfsteal_certbot() (
    local directory=$STATE_DIR/nginx-certbot
    umask 022
    certbot --config-dir "$directory/config" --work-dir "$directory/work" --logs-dir "$directory/logs" "$@"
)

_nginx_selfsteal_enable_renewal() {
    local domain=${NODE_DOMAIN%.} directory=$STATE_DIR/nginx-certbot stage
    stage=$(mktemp -d /etc/systemd/system/.remna-certbot.XXXXXX) || return 1
    if ! cat > "$stage/service" <<EOF_SERVICE
$_selfsteal_marker
[Unit]
Description=Renew the Remna Node Setup HTTPS certificate
Wants=network-online.target
After=network-online.target nginx.service
Requisite=nginx.service
ConditionPathExists=$_nginx_selfsteal_config

[Service]
Type=oneshot
UMask=0022
ExecStart=/usr/bin/certbot --config-dir "$directory/config" --work-dir "$directory/work" --logs-dir "$directory/logs" renew --cert-name "$domain" --quiet --deploy-hook "/usr/bin/systemctl reload nginx.service"
EOF_SERVICE
    then
        rm -rf -- "$stage"
        return 1
    fi
    if ! cat > "$stage/timer" <<EOF_TIMER
$_selfsteal_marker
[Unit]
Description=Renewal schedule for the Remna Node Setup HTTPS certificate

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=60m
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
    then
        rm -rf -- "$stage"
        return 1
    fi
    if ! install -m 0644 "$stage/service" "/etc/systemd/system/$_nginx_selfsteal_renewal.service" ||
        ! install -m 0644 "$stage/timer" "/etc/systemd/system/$_nginx_selfsteal_renewal.timer"; then
        rm -rf -- "$stage"
        return 1
    fi
    rm -rf -- "$stage" || return 1
    systemctl daemon-reload && systemctl enable --now "$_nginx_selfsteal_renewal.timer"
}

nginx_selfsteal_verify() {
    _selfsteal_nginx_owned_config && systemctl is-active --quiet nginx.service && _selfsteal_verify_https
}

nginx_selfsteal_apply() {
    local domain=${NODE_DOMAIN%.} attempt
    nginx_selfsteal_preflight && apt_install_missing nginx certbot || return 1
    install -d -m 0755 /etc/nginx/conf.d "$_selfsteal_site/.well-known/acme-challenge" || return 1
    if [[ ! -f $_selfsteal_site/index.html ]]; then
        install -m 0644 "$PROJECT_DIR/templates/index.html" "$_selfsteal_site/index.html" || return 1
    fi
    install -d -m 0700 "$STATE_DIR/nginx-certbot" || return 1

    if ! nginx_selfsteal_verify; then
        _nginx_selfsteal_activate_config http || return 1
    fi
    info "Certbot проверяет $domain через TCP 80."
    _nginx_selfsteal_certbot certonly --non-interactive --webroot --webroot-path "$_selfsteal_site" \
        --preferred-challenges http-01 --cert-name "$domain" -d "$domain" \
        --agree-tos --register-unsafely-without-email --keep-until-expiring || return 1

    _nginx_selfsteal_activate_config tls || return 1
    for ((attempt = 0; attempt < 5; attempt++)); do
        if nginx_selfsteal_verify; then
            _nginx_selfsteal_enable_renewal || return 1
            info 'Self-steal работает через Nginx. Certbot продлит сертификат автоматически.'
            return 0
        fi
        sleep 1
    done
    fail "Nginx не отвечает на 127.0.0.1:8443 с доверенным сертификатом для $domain."
}

nginx_selfsteal_stop() {
    _selfsteal_nginx_owned_config && nginx_selfsteal_preflight || return 1
    if [[ -f /etc/systemd/system/$_nginx_selfsteal_renewal.timer ]]; then
        systemctl disable --now "$_nginx_selfsteal_renewal.timer" || return 1
        systemctl stop "$_nginx_selfsteal_renewal.service" || return 1
    fi
    systemctl disable --now nginx.service
}
