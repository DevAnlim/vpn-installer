#!/usr/bin/env bash
#
# Помощник установки NaiveProxy/Caddy.
#
# Быстрый запуск:
#   chmod +x install.sh
#   sudo ./install.sh
#
# Справка:
#   ./install.sh --help

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

GO_VERSION="${GO_VERSION:-go1.26.2}"
XCADDY_MODULE="${XCADDY_MODULE:-github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.4}"
FORWARDPROXY_MODULE="${FORWARDPROXY_MODULE:-github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
RUN_SYSTEM_UPGRADE="${RUN_SYSTEM_UPGRADE:-0}"
UNINSTALL=false
ASSUME_YES=false
REMOVE_GO=false
REMOVE_WARP=false

WORK_DIR=""
SCRIPT_NAME="${0##*/}"

log() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

print_usage() {
  cat <<EOF
Установщик NaiveProxy/Caddy

Этот скрипт помогает быстро поставить Caddy с модулем NaiveProxy forward_proxy
на чистый Debian/Ubuntu-сервер. Он задает несколько вопросов, собирает Caddy,
создает systemd-сервис и печатает данные для подключения клиента.

Что нужно подготовить перед запуском:
  1. VPS/сервер на Debian или Ubuntu.
  2. Права root или пользователь с sudo.
  3. Домен, A-запись которого уже указывает на IP этого сервера.
  4. Открытые порты 80 и 443 в панели хостинга или фаерволе.
  5. Email для выпуска TLS-сертификата Let's Encrypt.

Самый простой запуск для новичка:
  chmod +x ${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME}

Посмотреть эту справку:
  ./${SCRIPT_NAME} --help

Запуск одной командой без вопросов:
  sudo ./${SCRIPT_NAME} \\
    --domain vpn.example.com \\
    --email admin@example.com \\
    --fake-site https://demo.cloudreve.org \\
    --user myuser \\
    --password 'long-safe-password'

Запуск с Cloudflare WARP:
  sudo ./${SCRIPT_NAME} --domain vpn.example.com --email admin@example.com --warp

Удаление установленного Caddy/NaiveProxy:
  sudo ./${SCRIPT_NAME} --uninstall

Удаление без вопросов для массового обслуживания:
  sudo ./${SCRIPT_NAME} --uninstall --yes

Удаление вместе с WARP или Go, если они больше не нужны на сервере:
  sudo ./${SCRIPT_NAME} --uninstall --remove-warp
  sudo ./${SCRIPT_NAME} --uninstall --remove-go

Переменные окружения для массовой установки:
  sudo env DOMAIN=vpn.example.com EMAIL=admin@example.com INSTALL_WARP=false ./${SCRIPT_NAME}

Полный apt upgrade по умолчанию выключен, чтобы установщик меньше трогал систему.
Если нужен полный upgrade перед установкой:
  sudo env RUN_SYSTEM_UPGRADE=1 ./${SCRIPT_NAME}

Опции:
  -h, --help                    показать эту справку
  -y, --yes                     не спрашивать подтверждение в опасных действиях
      --domain VALUE            домен сервера, например vpn.example.com
      --email VALUE             email для TLS/Let's Encrypt
      --fake-site VALUE         сайт-приманка, например https://demo.cloudreve.org
      --user VALUE              логин; если не указан, будет создан автоматически
      --password VALUE          пароль; если не указан, будет создан автоматически
      --warp                    установить Cloudflare WARP и подключить его как вышестоящий прокси
      --no-warp                 не устанавливать WARP
      --upgrade                 выполнить apt-get upgrade -y перед установкой
      --allow-private-fake-site разрешить частный IP-адрес в сайте-приманке
      --uninstall               удалить Caddy/NaiveProxy, созданные этим установщиком
      --remove-warp             вместе с --uninstall удалить Cloudflare WARP
      --remove-go               вместе с --uninstall удалить /usr/local/go и xcaddy

Важно про удаление:
  --uninstall удаляет сервис caddy, Caddyfile, данные Caddy, логи Caddy и
  /root/naiveproxy-client.json. Go и WARP по умолчанию остаются, потому что
  они могут использоваться другими задачами на сервере.

После установки:
  - Caddyfile: /etc/caddy/Caddyfile
  - сервис systemd: caddy
  - данные клиента: /root/naiveproxy-client.json
  - проверить статус: sudo systemctl status caddy
  - перезапустить: sudo systemctl restart caddy
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help)
        print_usage
        exit 0
        ;;
      -y|--yes)
        ASSUME_YES=true
        ;;
      --domain)
        shift
        [[ $# -gt 0 ]] || die "Для --domain нужно указать значение."
        DOMAIN="$1"
        ;;
      --domain=*)
        DOMAIN="${1#*=}"
        ;;
      --email)
        shift
        [[ $# -gt 0 ]] || die "Для --email нужно указать значение."
        EMAIL="$1"
        ;;
      --email=*)
        EMAIL="${1#*=}"
        ;;
      --fake-site)
        shift
        [[ $# -gt 0 ]] || die "Для --fake-site нужно указать значение."
        FAKE_SITE="$1"
        ;;
      --fake-site=*)
        FAKE_SITE="${1#*=}"
        ;;
      --user)
        shift
        [[ $# -gt 0 ]] || die "Для --user нужно указать значение."
        USER_NAME="$1"
        ;;
      --user=*)
        USER_NAME="${1#*=}"
        ;;
      --password)
        shift
        [[ $# -gt 0 ]] || die "Для --password нужно указать значение."
        USER_PASS="$1"
        ;;
      --password=*)
        USER_PASS="${1#*=}"
        ;;
      --warp)
        INSTALL_WARP=true
        ;;
      --no-warp)
        INSTALL_WARP=false
        ;;
      --upgrade)
        RUN_SYSTEM_UPGRADE=1
        ;;
      --allow-private-fake-site)
        ALLOW_PRIVATE_FAKE_SITE=1
        ;;
      --uninstall)
        UNINSTALL=true
        ;;
      --remove-warp)
        REMOVE_WARP=true
        ;;
      --remove-go)
        REMOVE_GO=true
        ;;
      --)
        shift
        break
        ;;
      *)
        die "Неизвестная опция: $1. Для справки запусти ./${SCRIPT_NAME} --help"
        ;;
    esac
    shift
  done
}

confirm_uninstall() {
  local answer=""

  if [[ "${ASSUME_YES}" == "true" ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    die "Удаление без интерактивного ввода требует флаг --yes."
  fi

  cat <<EOF
Будет удалено:
  - systemd service caddy;
  - бинарник Caddy, установленный этим скриптом;
  - /etc/caddy;
  - /var/lib/caddy;
  - /var/log/caddy;
  - /root/naiveproxy-client.json.
EOF

  if [[ "${REMOVE_WARP}" == "true" ]]; then
    printf 'Дополнительно будет удален Cloudflare WARP.\n'
  fi
  if [[ "${REMOVE_GO}" == "true" ]]; then
    printf 'Дополнительно будет удален /usr/local/go и /usr/local/bin/xcaddy.\n'
  fi

  read -r -p "Продолжить удаление? [y/N]: " answer || true
  case "$(lowercase "${answer}")" in
    y|yes) ;;
    *) die "Удаление отменено." ;;
  esac
}

remove_if_exists() {
  local path="$1"

  if [[ -e "${path}" || -L "${path}" ]]; then
    log "Удаление ${path}"
    rm -rf -- "${path}"
  fi
}

remove_profile_go_path() {
  local profile="/root/.profile"
  local tmp_file

  [[ -f "${profile}" ]] || return 0
  tmp_file="$(mktemp)"
  grep -Fvx 'export PATH="/usr/local/go/bin:$PATH"' "${profile}" > "${tmp_file}" || true
  cat "${tmp_file}" > "${profile}"
  rm -f "${tmp_file}"
}

uninstall_warp() {
  [[ "${REMOVE_WARP}" == "true" ]] || return 0
  require_debian_like

  log "Удаление Cloudflare WARP"
  systemctl disable --now warp-svc >/dev/null 2>&1 || true
  apt-get purge -y cloudflare-warp || true
  remove_if_exists /etc/apt/sources.list.d/cloudflare-client.list
  remove_if_exists /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  apt-get update || warn "Не удалось обновить список пакетов после удаления WARP."
}

uninstall_go() {
  [[ "${REMOVE_GO}" == "true" ]] || return 0

  log "Удаление Go из /usr/local/go"
  remove_if_exists /usr/local/go
  remove_if_exists /usr/local/bin/xcaddy
  remove_profile_go_path
}

uninstall_installed_stack() {
  local service_file="/etc/systemd/system/caddy.service"
  local remove_usr_bin_caddy=false

  confirm_uninstall

  if [[ -f "${service_file}" ]] && grep -Eq 'NaiveProxy|forward proxy|/usr/bin/caddy|/usr/local/bin/caddy' "${service_file}"; then
    remove_usr_bin_caddy=true
  fi

  log "Остановка сервиса Caddy, если он существует"
  systemctl disable --now caddy >/dev/null 2>&1 || true
  remove_if_exists "${service_file}"
  systemctl daemon-reload
  systemctl reset-failed caddy >/dev/null 2>&1 || true

  remove_if_exists /usr/local/bin/caddy
  if [[ "${remove_usr_bin_caddy}" == "true" ]]; then
    remove_if_exists /usr/bin/caddy
  else
    warn "Не удаляю /usr/bin/caddy автоматически: файл может принадлежать системному пакету."
  fi

  remove_if_exists /etc/caddy
  remove_if_exists /var/lib/caddy
  remove_if_exists /var/log/caddy
  remove_if_exists /root/naiveproxy-client.json

  if id -u caddy >/dev/null 2>&1; then
    log "Удаление пользователя caddy"
    userdel caddy >/dev/null 2>&1 || warn "Не удалось удалить пользователя caddy."
  fi
  if getent group caddy >/dev/null 2>&1; then
    log "Удаление группы caddy"
    groupdel caddy >/dev/null 2>&1 || warn "Не удалось удалить группу caddy."
  fi

  uninstall_warp
  uninstall_go

  printf '\n'
  printf '============================================================\n'
  printf 'Удаление завершено\n'
  printf '============================================================\n'
  printf 'Проверить, что сервис удален:\n'
  printf '  systemctl status caddy\n'
  printf '\n'
  if [[ "${REMOVE_WARP}" != "true" ]]; then
    printf 'WARP не удалялся. Чтобы удалить его тоже:\n'
    printf '  sudo ./%s --uninstall --remove-warp\n' "${SCRIPT_NAME}"
  fi
  if [[ "${REMOVE_GO}" != "true" ]]; then
    printf 'Go не удалялся. Чтобы удалить его тоже:\n'
    printf '  sudo ./%s --uninstall --remove-go\n' "${SCRIPT_NAME}"
  fi
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root или через sudo."
}

require_linux_systemd() {
  [[ "$(uname -s)" == "Linux" ]] || die "Этот установщик поддерживает только Linux."
  command -v systemctl >/dev/null 2>&1 || die "Для установки нужен systemd."
  [[ -d /run/systemd/system ]] || die "Похоже, systemd на этом сервере не запущен."
}

require_debian_like() {
  [[ -r /etc/os-release ]] || die "Не найден файл /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|*:debian*|*:ubuntu*) ;;
    *) die "Этот установщик рассчитан на Debian/Ubuntu или совместимую систему с apt." ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die "Для установки нужен apt-get."
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local secret="${4:-false}"
  local value=""

  if [[ -n "${!var_name:-}" ]]; then
    return
  fi

  if [[ -t 0 ]]; then
    if [[ "${secret}" == "true" ]]; then
      read -r -s -p "${prompt}" value || true
      printf '\n'
    else
      read -r -p "${prompt}" value || true
    fi
    value="${value:-${default_value}}"
  else
    value="${default_value}"
  fi

  printf -v "${var_name}" '%s' "${value}"
}

prompt_bool() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value=""

  if [[ -n "${!var_name:-}" ]]; then
    value="${!var_name}"
  elif [[ -t 0 ]]; then
    read -r -p "${prompt}" value || true
    value="${value:-${default_value}}"
  else
    value="${default_value}"
  fi

  case "$(lowercase "${value}")" in
    y|yes|true|1) printf -v "${var_name}" '%s' "true" ;;
    n|no|false|0|"") printf -v "${var_name}" '%s' "false" ;;
    *) die "Неверное значение для ${var_name}: ${value}. Используй y или n." ;;
  esac
}

validate_domain() {
  local value="$1"
  [[ "${value}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
    || die "Неверный домен: ${value}"
}

validate_email() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] \
    || die "Неверный email: ${value}"
}

is_private_ipv4() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "${ip}"
  [[ "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ && "${c}" =~ ^[0-9]+$ && "${d}" =~ ^[0-9]+$ ]] || return 1
  (( a >= 0 && a <= 255 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 0 && d <= 255 )) || return 1
  (( a == 10 )) && return 0
  (( a == 127 )) && return 0
  (( a == 169 && b == 254 )) && return 0
  (( a == 172 && b >= 16 && b <= 31 )) && return 0
  (( a == 192 && b == 168 )) && return 0
  return 1
}

validate_fake_site() {
  local value="$1"
  local host_port host

  [[ "${value}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] \
    || die "Сайт-приманка должен выглядеть как https://example.com или https://example.com:443"

  host_port="${value#*://}"
  host="${host_port%%:*}"
  case "$(lowercase "${host}")" in
    localhost|*.localhost) die "Сайт-приманка не должен указывать на localhost." ;;
  esac

  if is_private_ipv4 "${host}" && [[ "${ALLOW_PRIVATE_FAKE_SITE:-0}" != "1" ]]; then
    die "Сайт-приманка указывает на частный IPv4-адрес. Если это точно нужно, запусти с ALLOW_PRIVATE_FAKE_SITE=1."
  fi
}

validate_credential() {
  local name="$1"
  local value="$2"
  local min_length="$3"
  local max_length="$4"

  (( ${#value} >= min_length && ${#value} <= max_length )) \
    || die "${name}: длина должна быть от ${min_length} до ${max_length} символов."
  [[ "${value}" =~ ^[A-Za-z0-9._~-]+$ ]] \
    || die "${name}: разрешены только латинские буквы, цифры, точка, нижнее подчеркивание, тильда и дефис."
}

generate_credentials() {
  if [[ -z "${USER_NAME:-}" ]]; then
    USER_NAME="u$(openssl rand -hex 6)"
  fi
  if [[ -z "${USER_PASS:-}" ]]; then
    USER_PASS="$(openssl rand -hex 18)"
  fi
}

detect_go_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      GO_ARCH="amd64"
      GO_SHA256="990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282"
      ;;
    aarch64|arm64)
      GO_ARCH="arm64"
      GO_SHA256="c958a1fe1b361391db163a485e21f5f228142d6f8b584f6bef89b26f66dc5b23"
      ;;
    *)
      die "Неподдерживаемая архитектура CPU: $(uname -m)"
      ;;
  esac
}

ensure_line() {
  local file="$1"
  local line="$2"

  touch "${file}"
  grep -Fqx "${line}" "${file}" || printf '%s\n' "${line}" >> "${file}"
}

backup_file() {
  local path="$1"
  local backup_path

  if [[ -e "${path}" || -L "${path}" ]]; then
    backup_path="${path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${path}" "${backup_path}"
    log "Резервная копия ${path}: ${backup_path}"
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive

  log "Обновление списка пакетов apt"
  apt-get update

  if [[ "${RUN_SYSTEM_UPGRADE}" == "1" ]]; then
    log "Запуск apt-get upgrade, потому что RUN_SYSTEM_UPGRADE=1"
    apt-get upgrade -y
  else
    log "Полное обновление системы пропущено. Чтобы включить его, запусти с RUN_SYSTEM_UPGRADE=1."
  fi

  log "Установка базовых пакетов"
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    openssl \
    tar \
    wget
}

enable_bbr() {
  log "Включение BBR и настройка sysctl"
  cat > /etc/sysctl.d/99-naiveproxy-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  if ! sysctl --system; then
    warn "Не удалось применить sysctl сразу. Проверь, поддерживает ли ядро BBR."
  fi
}

install_go() {
  local archive="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  local url="https://go.dev/dl/${archive}"

  log "Скачивание ${archive}"
  curl -fL --proto '=https' --tlsv1.2 -o "${WORK_DIR}/${archive}" "${url}"

  log "Проверка контрольной суммы архива Go"
  (
    cd "${WORK_DIR}"
    printf '%s  %s\n' "${GO_SHA256}" "${archive}" | sha256sum -c -
  )

  log "Установка Go ${GO_VERSION}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${WORK_DIR}/${archive}"
  export PATH="/usr/local/go/bin:/usr/local/bin:${PATH}"
  ensure_line /root/.profile 'export PATH="/usr/local/go/bin:$PATH"'
}

build_caddy() {
  log "Установка xcaddy"
  GOBIN=/usr/local/bin go install "${XCADDY_MODULE}"

  log "Сборка Caddy с модулем NaiveProxy forward_proxy"
  (
    cd "${WORK_DIR}"
    /usr/local/bin/xcaddy build --with "${FORWARDPROXY_MODULE}"
  )

  [[ -x "${WORK_DIR}/caddy" ]] || die "Сборка Caddy не создала исполняемый файл."
}

ensure_caddy_user() {
  if ! getent group caddy >/dev/null 2>&1; then
    log "Создание системной группы caddy"
    groupadd --system caddy
  fi

  if ! id -u caddy >/dev/null 2>&1; then
    log "Создание системного пользователя caddy"
    useradd --system --gid caddy --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
  fi

  install -d -o root -g caddy -m 0750 /etc/caddy
  install -d -o caddy -g caddy -m 0750 /var/lib/caddy
  install -d -o caddy -g caddy -m 0750 /var/lib/caddy/.config
  install -d -o caddy -g caddy -m 0750 /var/log/caddy
}

write_caddyfile() {
  local warp_upstream=""

  if [[ "${INSTALL_WARP}" == "true" ]]; then
    warp_upstream="    upstream socks5://127.0.0.1:${WARP_PROXY_PORT}"
  fi

  log "Создание конфигурации Caddy: /etc/caddy/Caddyfile"
  backup_file /etc/caddy/Caddyfile

  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
  tls ${EMAIL}

  route {
    forward_proxy {
      basic_auth ${USER_NAME} ${USER_PASS}
      hide_ip
      hide_via
      probe_resistance
${warp_upstream}
    }

    reverse_proxy ${FAKE_SITE} {
      header_up Host {upstream_hostport}
      header_up X-Forwarded-Host {host}
    }
  }
}
EOF

  chown root:caddy /etc/caddy/Caddyfile
  chmod 0640 /etc/caddy/Caddyfile
}

install_caddy_binary() {
  log "Установка бинарника Caddy"
  backup_file /usr/local/bin/caddy
  install -m 0755 "${WORK_DIR}/caddy" /usr/local/bin/caddy
}

write_systemd_service() {
  log "Создание systemd-сервиса Caddy"
  backup_file /etc/systemd/system/caddy.service

  cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy с NaiveProxy
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_DATA_HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/caddy /var/log/caddy

[Install]
WantedBy=multi-user.target
EOF
}

install_warp() {
  local codename

  [[ "${INSTALL_WARP}" == "true" ]] || return 0

  log "Установка Cloudflare WARP"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL --proto '=https' --tlsv1.2 \
    https://pkg.cloudflareclient.com/pubkey.gpg \
    -o "${WORK_DIR}/cloudflare-warp-pubkey.gpg"
  gpg --batch --yes --dearmor \
    --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
    "${WORK_DIR}/cloudflare-warp-pubkey.gpg"
  chmod 0644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  codename="$(lsb_release -cs)"
  [[ "${codename}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Неверный код релиза дистрибутива: ${codename}"

  cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF

  apt-get update
  apt-get install -y --no-install-recommends cloudflare-warp

  systemctl enable --now warp-svc || warn "Не удалось автоматически включить warp-svc."
  warp-cli --accept-tos registration new || warn "Регистрация WARP, возможно, уже существует."
  warp-cli --accept-tos mode proxy
  warp-cli --accept-tos proxy port "${WARP_PROXY_PORT}" || warn "Не удалось задать порт прокси WARP; используется значение WARP по умолчанию."
  warp-cli --accept-tos connect || warn "Не удалось автоматически подключить WARP."
}

validate_and_start_caddy() {
  log "Проверка конфигурации Caddy"
  /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile

  log "Запуск Caddy через systemd"
  systemctl daemon-reload
  systemctl enable caddy
  systemctl restart caddy
  systemctl --no-pager --full status caddy >/dev/null
}

write_client_config() {
  local path="/root/naiveproxy-client.json"

  log "Запись клиентского конфига в ${path}"
  cat > "${path}" <<EOF
{
  "listen": "socks://127.0.0.1:20808",
  "proxy": "https://${USER_NAME}:${USER_PASS}@${DOMAIN}"
}
EOF
  chmod 0600 "${path}"
}

collect_input() {
  cat <<'EOF'
==============================
VPN INSTALLER - УСТАНОВКА
==============================
Этот помощник установит Caddy + NaiveProxy forward_proxy.

Что нужно перед установкой:
  1. VPS/сервер на Debian или Ubuntu.
  2. Домен уже указывает на IP этого сервера.
  3. Порты 80 и 443 открыты.
  4. Скрипт запущен от root или через sudo.

Если не знаешь, что вводить, оставь значение по умолчанию
там, где оно подходит. Логин и пароль можно оставить пустыми:
скрипт создаст безопасные случайные значения.

EOF

  prompt_value DOMAIN "🌐 Домен (например your-domain.com): " "your-domain.com"
  prompt_value EMAIL "📧 Email для SSL (example@example.com): " "example@example.com"
  prompt_value FAKE_SITE "🎭 Сайт-приманка (https://demo.cloudreve.org): " "https://demo.cloudreve.org"
  prompt_value USER_NAME "👤 Логин (оставь пустым = авто): " ""
  prompt_value USER_PASS "🔑 Пароль (оставь пустым = авто): " "" true
  prompt_bool INSTALL_WARP "⚡ Установить WARP? (y/n): " "n"

  generate_credentials
  validate_domain "${DOMAIN}"
  validate_email "${EMAIL}"
  validate_fake_site "${FAKE_SITE}"
  validate_credential "Логин" "${USER_NAME}" 3 64
  validate_credential "Пароль" "${USER_PASS}" 12 128
}

print_summary() {
  printf '\n'
  printf '============================================================\n'
  printf 'Установка завершена\n'
  printf '============================================================\n'
  printf 'Адрес сервера: https://%s\n' "${DOMAIN}"
  printf 'Логин: %s\n' "${USER_NAME}"
  printf 'Пароль: %s\n' "${USER_PASS}"
  printf 'Файл с данными клиента: /root/naiveproxy-client.json\n'
  printf 'Конфиг Caddy: /etc/caddy/Caddyfile\n'
  printf 'Сервис: caddy\n'
  if [[ "${INSTALL_WARP}" == "true" ]]; then
    printf 'WARP: включен, вышестоящий прокси socks5://127.0.0.1:%s добавлен в Caddyfile\n' "${WARP_PROXY_PORT}"
  else
    printf 'WARP: выключен\n'
  fi
  printf '\n'
  printf 'JSON для клиента:\n'
  cat /root/naiveproxy-client.json
  printf '\n'
  cat <<EOF
Полезные команды:
  sudo systemctl status caddy
  sudo systemctl restart caddy
  sudo journalctl -u caddy -n 100 --no-pager
  sudo caddy validate --config /etc/caddy/Caddyfile

Если сайт не открывается:
  1. Проверь, что DNS домена указывает на этот сервер.
  2. Проверь, что порты 80 и 443 открыты.
  3. Посмотри ошибки: sudo journalctl -u caddy -n 100 --no-pager
============================================================
EOF
}

main() {
  parse_args "$@"

  if [[ "${UNINSTALL}" != "true" && ( "${REMOVE_WARP}" == "true" || "${REMOVE_GO}" == "true" ) ]]; then
    die "--remove-warp и --remove-go можно использовать только вместе с --uninstall."
  fi

  require_root
  require_linux_systemd

  if [[ "${UNINSTALL}" == "true" ]]; then
    uninstall_installed_stack
    exit 0
  fi

  require_debian_like
  WORK_DIR="$(mktemp -d)"

  collect_input
  detect_go_arch
  install_packages
  enable_bbr
  install_go
  build_caddy
  ensure_caddy_user
  install_warp
  write_caddyfile
  install_caddy_binary
  write_systemd_service
  validate_and_start_caddy
  write_client_config
  print_summary
}

main "$@"
