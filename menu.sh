#!/usr/bin/env bash
set -uo pipefail

version=1.0.2
telemt_version=3.5.17
upstream_sha=ec61f3ec917a1a20b5ac6725cf60cb35884e44c882524d63cc65bd7266b06a8f
config_file=/etc/telemt/telemt.toml
unit_file=/etc/systemd/system/telemt.service
telemt_bin=/bin/telemt
launcher=/usr/local/bin/sevas-telemt-menu
shortcut=/usr/local/bin/menu
backup_root=/var/backups/sevas-telemt
lock_file=/run/lock/sevas-telemt-menu.lock

say() { printf '%s\n' "$*"; }
fail() { printf 'Ошибка: %s\n' "$*" >&2; return 1; }

ask() {
    printf '%s' "$1" >&2
    IFS= read -r REPLY
}

confirm() {
    ask "$1 [y/N]: " && [[ $REPLY == [yY] || $REPLY == [дД] ]]
}

require_host() {
    [[ $(uname -s) == Linux && $EUID == 0 ]] || { fail 'Нужен Linux с systemd. Войдите как root или используйте sudo.'; return 1; }
    [[ -d /run/systemd/system ]] || { fail 'На сервере не запущен systemd.'; return 1; }
    local command
    for command in curl python3 systemctl journalctl ss flock sha256sum; do
        command -v "$command" >/dev/null || { fail "Установите $command."; return 1; }
    done
    python3 -c 'import tomllib' 2>/dev/null || { fail 'Нужен Python 3.11 или новее.'; return 1; }
}

config() {
    python3 - "$config_file" "$@" <<'PY'
import copy
import ipaddress
import re
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlencode

path, action, *args = sys.argv[1:]

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

def domain_ok(host):
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    return len(host) <= 253 and re.fullmatch(rf"{label}(?:\.{label})+", host, re.I) is not None

if action == "domain":
    if not domain_ok(args[0]):
        fail("Укажите имя HTTPS-сайта без https://, порта и пути.")
    raise SystemExit(0)

try:
    raw = Path(path).read_bytes().decode("utf-8")
    data = tomllib.loads(raw)
except (OSError, UnicodeError, ValueError):
    fail("Не удалось прочитать конфигурацию Telemt. Проверьте её в /etc/telemt/telemt.toml.")

general = data.get("general", {})
server = data.get("server", {})
access = data.get("access", {})
users = access.get("users", {})
port = server.get("port", 443)
tls_domain = data.get("censorship", {}).get("tls_domain", "petrovich.ru")

if action == "port":
    print(port)
elif action == "domain-current":
    print(tls_domain)
elif action == "api":
    print("on" if server.get("api", {}).get("enabled", False) else "off")
elif action == "status":
    print(f"Порт в конфиге: {port}/tcp")
    print(f"TLS-домен: {tls_domain}")
    print("Общий тег спонсора: " + ("задан" if general.get("ad_tag") else "не задан"))
    print("Telegram Middle Proxy: " + ("включён" if general.get("use_middle_proxy") else "выключен"))
    if access.get("user_ad_tags"):
        print("В конфиге также заданы индивидуальные теги спонсора.")
elif action in ("link", "register"):
    host, username = args
    try:
        host = str(ipaddress.ip_address(host))
    except ValueError:
        if action == "register" or not domain_ok(host):
            fail("Для регистрации укажите публичный IP; для клиентской ссылки подойдёт также домен.")
    if server.get("listeners"):
        print("Убедитесь, что в ссылке указан внешний порт нужного listener.", file=sys.stderr)
    secret = users.get(username or "hello")
    if not isinstance(secret, str) or not re.fullmatch(r"[0-9a-fA-F]{32}", secret):
        fail("Пользователь не найден или у него нет 32-символьного ключа. Имена: " + ", ".join(users))
    if action == "register":
        print(f"Адрес для @MTProxybot: [{host}]:{port}" if ":" in host else f"Адрес для @MTProxybot: {host}:{port}")
        print(f"Ключ для @MTProxybot: {secret}")
    else:
        if not domain_ok(tls_domain) or not general.get("modes", {}).get("tls", True):
            fail("Ссылка ee требует включённого Fake TLS и корректного tls_domain.")
        ee = "ee" + secret.lower() + tls_domain.encode("ascii").hex()
        print("https://t.me/proxy?" + urlencode({"server": host, "port": port, "secret": ee}))
elif action == "tag":
    tag = args[0]
    if tag and not re.fullmatch(r"[0-9a-fA-F]{32}", tag):
        fail("Тег спонсора должен содержать ровно 32 шестнадцатеричных символа.")
    tag = tag.lower()
    expected = copy.deepcopy(data)
    target = expected.setdefault("general", {})
    if tag:
        target["ad_tag"] = tag
        target["use_middle_proxy"] = True
    else:
        target.pop("ad_tag", None)

    if expected == data or (not tag and "general" not in data):
        sys.stdout.buffer.write(raw.encode("utf-8"))
        raise SystemExit(0)

    lines = raw.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if re.fullmatch(r"\s*\[general\]\s*(?:#.*)?\r?\n?", line)), None)
    newline = "\r\n" if "\r\n" in raw else "\n"
    changed = ["ad_tag"]
    new_entries = []
    if tag:
        changed.append("use_middle_proxy")
        new_entries = [f'ad_tag = "{tag}"{newline}', f"use_middle_proxy = true{newline}"]
    if start is None:
        candidate = "[general]" + newline + "".join(new_entries) + newline + raw
    else:
        end = next((i for i in range(start + 1, len(lines)) if re.match(r"^\s*\[", lines[i])), len(lines))
        pattern = re.compile(r"^\s*(?:" + "|".join(changed) + r")\s*=")
        kept = [line for line in lines[start + 1:end] if not pattern.match(line)]
        header = lines[start] if lines[start].endswith("\n") else lines[start] + newline
        candidate = "".join(lines[:start] + [header] + new_entries + kept + lines[end:])
    try:
        checked = tomllib.loads(candidate)
    except ValueError:
        checked = None
    if checked != expected:
        fail("Нестандартная запись параметров [general]. Конфигурация оставлена как есть.")
    sys.stdout.buffer.write(candidate.encode("utf-8"))
else:
    fail("Неизвестная операция над конфигурацией.")
PY
}

lock() {
    exec 9>"$lock_file" || return 1
    flock -n 9 || { fail 'Другая операция Telemt уже выполняется.'; return 1; }
}

require_native() {
    [[ -f $config_file && ! -L $config_file && -x $telemt_bin && -f $unit_file ]] ||
        { fail 'Нужна штатная установка Telemt с systemd и конфигом /etc/telemt/telemt.toml.'; return 1; }
    local command
    command=$(systemctl show -p ExecStart --value telemt.service) || return 1
    [[ $command == *"$config_file"* ]] ||
        { fail 'Служба Telemt использует другой конфиг.'; return 1; }
}

started() {
    local port pid listeners
    port=$(config port) || return 1
    systemctl is-active --quiet telemt.service || return 1
    pid=$(systemctl show -p MainPID --value telemt.service) || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    listeners=$(ss -Hltnp "( sport = :$port )") || return 1
    [[ $listeners == *"pid=$pid,"* ]]
}

api_ready() {
    local api
    api=$(config api) || return 1
    [[ $api != on ]] ||
        timeout 8 "$telemt_bin" healthcheck --mode ready "$config_file" >/dev/null 2>&1
}

wait_for() {
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        (( SECONDS < deadline )) || return 1
        sleep 1
    done
}

report_api_health() {
    local api
    api=$(config api) || return 1
    [[ $api == on ]] || return 0
    if api_ready; then
        say 'API Telemt подтвердил готовность.'
    else
        say 'API Telemt пока не подтвердил готовность. Проверьте журнал и подключение в Telegram.' >&2
        return 1
    fi
}

status() {
    require_native || return 1
    config status || return 1
    if started; then
        say 'Служба запущена и слушает настроенный TCP-порт.'
        report_api_health
    else
        fail 'Проверка готовности не прошла. Посмотрите пункт «Журнал».'
    fi
}

backup() {
    mkdir -p -- "$backup_root" && chmod 700 -- "$backup_root" || return 1
    mktemp -d -- "$backup_root/$(date +%Y%m%d-%H%M%S).XXXXXX"
}

restore_file() (
    local source=$1 target=$2 staged
    staged=$(mktemp -- "$target.restore.XXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT
    cp -a -- "$source" "$staged" && mv -fT -- "$staged" "$target"
)

prepare_upstream() {
    # On systemd the unit supplies the capabilities, so the extra setcap package is unnecessary.
    sed -i -E \
        -e 's/curl -fsSL "\$1" -o "\$2"/curl --connect-timeout 15 --max-time 60 --speed-limit 1024 --speed-time 20 -fsSL "$1" -o "$2"/' \
        -e 's/if ! command -v setcap /if [ "$(get_svc_mgr)" != "systemd" ] \&\& ! command -v setcap /' \
        "$1"
}

upstream() (
    local installer digest
    installer=$(mktemp) || return 1
    trap 'rm -f -- "$installer"' EXIT
    curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 60 \
        "https://raw.githubusercontent.com/telemt/telemt/$telemt_version/install.sh" -o "$installer" || return 1
    digest=$(sha256sum "$installer") || return 1
    [[ "${digest%% *}" == "$upstream_sha" ]] || { fail 'Контрольная сумма установщика Telemt отличается.'; return 1; }
    prepare_upstream "$installer" || return 1
    env -u VERSION -u TLS_DOMAIN -u SERVER_PORT -u SUDO \
        REPO=telemt/telemt BIN_NAME=telemt INSTALL_DIR=/bin CONFIG_DIR=/etc/telemt \
        CONFIG_FILE="$config_file" WORK_DIR=/opt/telemt /bin/sh "$installer" --lang ru "$@"
)

show_install_progress() {
    sed -u -n -E '
        /(tg:\/\/proxy|https:\/\/t\.me\/proxy)\?/d
        s/[[:xdigit:]]{32,}/[скрыто]/g
        /^(\[INFO\] )?>>> /p
        /^\[(ERROR|WARNING)\]/p
        /^curl: \([0-9]+\)/p
        /^Ошибка:/p
    '
}

install_proxy() (
    lock || return 1
    local port domain saved='' was_active=0 was_ready=0 updating=0
    if [[ -e $unit_file || -e $telemt_bin ]]; then
        require_native || return 1
        updating=1
    fi
    if [[ -e $config_file || -L $config_file ]]; then
        [[ -f $config_file && ! -L $config_file ]] ||
            { fail 'Ожидается обычный файл конфигурации Telemt.'; return 1; }
        port=$(config port) || return 1
        domain=$(config domain-current) || return 1
        saved=$(backup) || return 1
        cp -a -- "$config_file" "$saved/" || return 1
        if [[ $updating == 1 ]]; then
            confirm "Установить Telemt $telemt_version поверх текущей версии с коротким перезапуском?" || return 0
            if systemctl is-active --quiet telemt.service; then
                was_active=1
                if started && api_ready; then was_ready=1; fi
            fi
            cp -a -- "$unit_file" "$telemt_bin" "$saved/" || return 1
        fi
    else
        ask 'TCP-порт [443]: ' || return 1
        port=${REPLY:-443}
        ask 'TLS-домен HTTPS-сайта [petrovich.ru]: ' || return 1
        domain=${REPLY:-petrovich.ru}
    fi
    [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port > 0 && 10#$port <= 65535)) ||
        { fail 'Введите порт от 1 до 65535.'; return 1; }
    port=$((10#$port))
    config domain "$domain" || return 1
    if [[ $updating == 0 && -n $(ss -Hltn "( sport = :$port )") ]]; then
        fail "Порт $port занят. Выберите свободный порт или другой сервер."
        return 1
    fi

    say "Загружаю установщик Telemt $telemt_version с GitHub…"
    if ! upstream "$telemt_version" --port "$port" --domain "$domain" 2>&1 | show_install_progress; then
        say 'Официальный установщик Telemt завершился с ошибкой.' >&2
    elif ! { say "Проверяю запуск службы на $port/tcp (до 20 секунд)…"; wait_for 20 started; }; then
        say "Служба Telemt не начала слушать $port/tcp за 20 секунд. Проверьте пункт «Журнал»." >&2
    elif [[ $was_ready == 1 ]] && ! { say 'Проверяю готовность API после обновления…'; wait_for 45 api_ready; }; then
        say 'До обновления Telemt был готов, но после обновления API не подтвердил готовность.' >&2
    else
        say "Telemt запущен на $port/tcp. Ссылку можно открыть в пункте 4."
        report_api_health || true
        say 'Если сервер закрыт файрволом, проверьте входящий TCP в панели хостинга.'
        return 0
    fi

    if [[ $updating == 1 ]]; then
        if restore_file "$saved/telemt.toml" "$config_file" &&
            restore_file "$saved/telemt.service" "$unit_file" &&
            restore_file "$saved/telemt" "$telemt_bin" &&
            systemctl daemon-reload; then
            if [[ $was_active == 1 ]]; then
                systemctl restart telemt.service || { fail "Старая версия восстановлена, но служба не запустилась. Копия: $saved"; return 1; }
            else
                systemctl stop telemt.service || return 1
            fi
            fail "Обновление не прошло проверку. Предыдущие файлы восстановлены. Копия: $saved"
        else
            fail "Обновление прервалось, автоматический откат не завершён. Копия: $saved"
        fi
    else
        if [[ -n $saved ]]; then
            if restore_file "$saved/telemt.toml" "$config_file"; then
                say "Предыдущий конфиг восстановлен. Копия: $saved"
            else
                fail "Конфиг сохранён в $saved."
            fi
        fi
        fail 'Установку или запуск не удалось подтвердить. Проверьте журнал Telemt и занятость порта.'
    fi
    return 1
)

change_tag() (
    lock && require_native || return 1
    local tag=$1 staged saved was_active=0
    staged=$(mktemp -- "${config_file}.menu.XXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT
    config tag "$tag" >"$staged" || return 1
    if cmp -s -- "$config_file" "$staged"; then
        say 'Настройка уже такая.'
        return 0
    fi
    saved=$(backup) || return 1
    cp -a -- "$config_file" "$saved/telemt.toml" || return 1
    chown --reference="$config_file" -- "$staged" &&
        chmod --reference="$config_file" -- "$staged" || return 1
    if systemctl is-active --quiet telemt.service; then was_active=1; fi
    mv -fT -- "$staged" "$config_file" || return 1
    if [[ $was_active == 0 ]] || { systemctl restart telemt.service && wait_for 20 started && wait_for 45 api_ready; }; then
        say "Настройка сохранена. Резервная копия: $saved"
        if [[ $was_active == 0 ]]; then say 'Настройка вступит в силу при следующем запуске службы.'; fi
        return 0
    fi
    if cp -a -- "$saved/telemt.toml" "$staged" &&
        mv -fT -- "$staged" "$config_file" &&
        systemctl restart telemt.service; then
        fail 'После изменения служба не прошла проверку. Старый конфиг восстановлен.'
    else
        fail "Откат не завершён. Конфиг сохранён в $saved."
    fi
    return 1
)

show_link() {
    require_native || return 1
    local host
    if [[ $1 == register ]]; then
        say 'Отправляйте ключ только официальному боту @MTProxybot.'
    fi
    ask 'Публичный IP сервера (для клиентской ссылки можно домен): ' || return 1
    host=$REPLY
    ask 'Имя пользователя в Telemt [hello]: ' || return 1
    config "$1" "$host" "${REPLY:-hello}"
}

sponsor() {
    require_native || return 1
    say 'Канал-спонсор'
    say '1. Показать данные для /newproxy в @MTProxybot'
    say '2. Добавить или заменить ad_tag от @MTProxybot'
    say '3. Отключить общий тег'
    say '0. Назад'
    ask 'Выбор: ' || return 1
    case $REPLY in
        1) show_link register ;;
        2)
            ask 'Тег от бота (32 hex): ' || return 1
            local tag=$REPLY
            [[ $tag =~ ^[[:xdigit:]]{32}$ ]] || { fail 'Нужен тег из 32 символов 0–9 и a–f.'; return 1; }
            if confirm 'Сохранить тег и применить изменения?'; then
                change_tag "$tag" && say 'В @MTProxybot откройте /myproxies → Set promotion и выберите публичный канал.'
            fi ;;
        3) if confirm 'Убрать общий тег и применить изменения?'; then change_tag ''; fi ;;
        0) return 0 ;;
        *) fail 'Неизвестный пункт.' ;;
    esac
}

restart_proxy() (
    lock && require_native || return 1
    systemctl restart telemt.service && wait_for 20 started && status
)

remove_proxy() (
    lock && require_native || return 1
    ask 'Удалить службу и бинарник Telemt, сохранив конфиг? Введите УДАЛИТЬ: ' || return 1
    [[ $REPLY == УДАЛИТЬ ]] || return 0
    upstream uninstall || return 1
    say "Конфиг сохранён в $config_file."
)

menu() {
    while true; do
        printf '\nSevas-Ping.pro · Telemt\n'
        say '1. Установить или обновить'
        say '2. Проверить статус'
        say '3. Перезапустить'
        say '4. Показать ссылку для Telegram'
        say '5. Канал-спонсор'
        say '6. Журнал'
        say '7. Удалить службу с сохранением конфига'
        say '0. Выход'
        ask 'Выбор: ' || return 0
        case $REPLY in
            1) install_proxy ;;
            2) status ;;
            3) restart_proxy ;;
            4) show_link link ;;
            5) sponsor ;;
            6) journalctl -u telemt.service -n 70 --no-pager ;;
            7) remove_proxy ;;
            0) return 0 ;;
            *) fail 'Неизвестный пункт.' ;;
        esac
    done
}

setup() (
    lock || return 1
    local source=$1 current staged
    [[ -f $source && $source != /dev/* && $source != /proc/* ]] ||
        { fail 'Скачайте скрипт в файл и запустите его с параметром setup.'; return 1; }
    if [[ -e $launcher || -L $launcher ]]; then
        [[ -f $launcher && ! -L $launcher ]] && grep -qx '# Sevas-Ping Telemt menu' "$launcher" ||
            { fail "Путь $launcher занят другой программой."; return 1; }
    fi
    staged=$(mktemp -- "$launcher.XXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT
    install -m 0755 -- "$source" "$staged" && mv -fT -- "$staged" "$launcher" || return 1
    current=$(type -P menu || true)
    if [[ -L $shortcut && $(readlink -- "$shortcut") == "$launcher" ]]; then
        say 'Меню установлено. Команда: menu'
    elif [[ -e $shortcut || -L $shortcut || -n $current ]]; then
        say 'Имя menu уже занято. Для Telemt используйте sevas-telemt-menu.'
    else
        ln -s -- "$launcher" "$shortcut" || return 1
        say 'Меню установлено. Команда: menu'
    fi
)

main() {
    case ${1:-menu} in
        --help|-h) say 'Использование: menu [setup|status|logs|sponsor|--version]'; return 0 ;;
        --version) say "Sevas-Ping Telemt menu $version"; return 0 ;;
    esac
    require_host || return 1
    case ${1:-menu} in
        setup) setup "$0" && menu ;;
        menu) menu ;;
        status) status ;;
        logs) journalctl -u telemt.service -n 70 --no-pager ;;
        sponsor) sponsor ;;
        *) fail 'Неизвестная команда. Используйте menu --help.' ;;
    esac
}

# Sevas-Ping Telemt menu
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
