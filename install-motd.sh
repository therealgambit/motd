#!/bin/bash
set -euo pipefail

# ----------------- Абсолютные пути к системным утилитам -----------------
readonly TOILET="/usr/bin/toilet"
readonly LAST="/usr/bin/last"
readonly LASTLOG="/usr/bin/lastlog"
readonly WHO="/usr/bin/who"
readonly UPTIME="/usr/bin/uptime"
readonly HOSTNAME="/bin/hostname"
readonly LSB_RELEASE="/usr/bin/lsb-release"
readonly IP="/sbin/ip"
readonly UNAME="/bin/uname"
readonly VMSTAT="/usr/bin/vmstat"
readonly FREE="/usr/bin/free"
readonly DF="/bin/df"
readonly CAT="/bin/cat"
readonly AWK="/usr/bin/awk"
readonly CUT="/usr/bin/cut"
readonly HEAD="/usr/bin/head"
readonly TAIL="/usr/bin/tail"
readonly GREP="/bin/grep"
readonly SED="/bin/sed"
readonly DOCKER="/usr/bin/docker"
readonly WC="/usr/bin/wc"

# ------------------- Пути используемых файлов -------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly CONFIG_FILE="/etc/dist-motd.conf"
readonly MOTD_SCRIPT="/etc/update-motd.d/00-dist-motd"
readonly APT_CONF_FILE="/etc/apt/apt.conf.d/99force-ipv4"
readonly CMD_MOTD="/usr/local/bin/motd"
readonly CMD_SETTINGS="/usr/local/bin/motd-set"

readonly BACKUP_ROOT="/opt/motd/complete-backup"
readonly INSTALL_MARKER="/opt/motd/custom_motd_installed"
readonly DIRECTORIES_TO_BACKUP=(
    "/etc/update-motd.d"
    "/etc/pam.d"
    "/etc/ssh"
    "/usr/local/bin"
)

readonly APT_GET="/usr/bin/apt-get"
readonly MKDIR="/bin/mkdir"
readonly CHMOD="/bin/chmod"
readonly RM="/bin/rm"
readonly CP="/bin/cp"
readonly LN="/bin/ln"
readonly SYSTEMCTL="/bin/systemctl"
readonly DATE="/bin/date"
readonly TAR="/bin/tar"
readonly RSYNC="/usr/bin/rsync"

# ----------------- Логгирование -----------------
log_info()   { echo "[+] $*" >&2; }
log_warn()   { echo "[!] Warning: $*" >&2; }
log_error()  { echo "[!] Error: $*" >&2; }

# ----------------- Универсальные утилиты -----------------
safe_cmd() {
    local cmd_output
    if cmd_output=$("$@" 2>/dev/null); then
        printf '%s' "${cmd_output}"
    else
        printf 'N/A'
    fi
}

check_root() { [[ "${EUID}" -ne 0 ]] && { log_error "Требуются права root"; exit 1; }; }

check_backup_exists() { [[ -f "${INSTALL_MARKER}" ]] && [[ -d "${BACKUP_ROOT}" ]]; }

# ----------------- Определение системы -----------------
detect_system_version() {
    if [[ -f "/etc/os-release" ]]; then
        local os_id
        os_id=$("${GREP}" "^ID=" /etc/os-release | "${CUT}" -d= -f2 | tr -d '"')
        case "${os_id}" in
            ubuntu)
                SYSTEM_TYPE="ubuntu"
                SYSTEM_VERSION=$("${GREP}" "^VERSION_ID=" /etc/os-release | "${CUT}" -d= -f2 | tr -d '"')
                ;;
            debian)
                SYSTEM_TYPE="debian"
                SYSTEM_VERSION=$("${CAT}" /etc/debian_version | "${CUT}" -d. -f1)
                ;;
            *)
                SYSTEM_TYPE="${os_id}"
                SYSTEM_VERSION=$("${GREP}" "^VERSION_ID=" /etc/os-release | "${CUT}" -d= -f2 | tr -d '"')
                ;;
        esac
    else
        log_error "Не удалось определить систему!"
        exit 1
    fi
    log_info "Обнаружена система: ${SYSTEM_TYPE} ${SYSTEM_VERSION}"
}

# ----------------- Валидация -----------------
validate_system() {
    detect_system_version
    if [[ "${SYSTEM_TYPE}" == "debian" ]] && [[ "${SYSTEM_VERSION}" -lt 11 ]]; then
        log_error "Поддерживаются только Debian 11+"
        exit 1
    fi
    if [[ "${SYSTEM_TYPE}" == "ubuntu" ]]; then
        local um=$(( $(echo $SYSTEM_VERSION | cut -d. -f1)*100 + $(echo $SYSTEM_VERSION | cut -d. -f2) ))
        if [[ "$um" -lt 2204 ]]; then
            log_error "Поддерживаются только Ubuntu 22.04+"
            exit 1
        fi
    fi
}

# ----------------- Бэкап директорий -----------------
create_complete_directory_backup() {
    log_info "Создание полного бэкапа..."
    "${MKDIR}" -p "${BACKUP_ROOT}"
    "${CHMOD}" 700 "${BACKUP_ROOT}"
    for dir in "${DIRECTORIES_TO_BACKUP[@]}"; do
        if [[ -d "$dir" ]]; then
            local bn=$(echo "$dir" | "${SED}" 's|/|_|g' | "${SED}" 's|^_||')
            if command -v rsync >/dev/null; then
                "${RSYNC}" -a --delete "$dir/" "${BACKUP_ROOT}/${bn}/"
            else
                "${RM}" -rf "${BACKUP_ROOT}/${bn}"
                "${CP}" -a "$dir" "${BACKUP_ROOT}/${bn}"
            fi
        fi
    done
    for file in /etc/motd /etc/bash.bashrc; do
        if [[ -f "$file" || -L "$file" ]]; then
            local bn=$(echo "$file" | "${SED}" 's|/|_|g' | "${SED}" 's|^_||')
            "${CP}" -a "$file" "${BACKUP_ROOT}/${bn}" || true
        fi
    done
    "${DATE}" > "${INSTALL_MARKER}"
}

# ----------------- Конфиг по умолчанию -----------------
create_config() {
    cat > "${CONFIG_FILE}" << 'EOF'
SHOW_LOGO=true
SHOW_CPU=true
SHOW_MEM=true
SHOW_NET=true
SHOW_DOCKER=true
SHOW_FIREWALL=true
SHOW_FIREWALL_RULES=false
SHOW_UPDATES=false
EOF
    "${CHMOD}" 644 "${CONFIG_FILE}"
}

# ----------------- Адаптивная установка зависимостей -----------------
install_dependencies() {
    log_info "Установка зависимостей..."
    if [[ ! -f "${APT_CONF_FILE}" ]]; then
        echo 'Acquire::ForceIPv4 "true";' > "${APT_CONF_FILE}"
        "${CHMOD}" 644 "${APT_CONF_FILE}"
    fi
    "${APT_GET}" update -qq || log_warn "Не удалось обновить список пакетов, продолжаем..."
    local packages=("toilet" "figlet" "procps" "lsb-release" "whiptail" "rsync")
    if [[ "${SYSTEM_TYPE}" == "debian" ]] && [[ "${SYSTEM_VERSION}" -ge 13 ]]; then
        packages+=("sqlite3")
    fi
    if [[ "${SYSTEM_TYPE}" == "ubuntu" ]]; then
        local ub_major ub_minor ub_numeric
        ub_major=$(echo "${SYSTEM_VERSION}" | "${CUT}" -d. -f1)
        ub_minor=$(echo "${SYSTEM_VERSION}" | "${CUT}" -d. -f2)
        ub_numeric=$((ub_major * 100 + ub_minor))
        if [[ "${ub_numeric}" -ge 2404 ]]; then
            packages+=("sqlite3")
        fi
    fi
    "${APT_GET}" install -y "${packages[@]}" >/dev/null || {
        log_error "Не удалось установить необходимые пакеты"
        exit 1
    }
    log_info "Зависимости установлены"
}

# ----------------- Основной скрипт MOTD -----------------
create_motd_script() {
    log_info "Создание MOTD скрипта..."
    "${MKDIR}" -p /etc/update-motd.d
    cat > "${MOTD_SCRIPT}" << MOTD_EOF
#!/bin/bash
if [[ -f "/etc/dist-motd.conf" ]]; then
    source "/etc/dist-motd.conf"
else
    SHOW_LOGO=true
    SHOW_CPU=true
    SHOW_MEM=true
    SHOW_NET=true
    SHOW_DOCKER=true
    SHOW_FIREWALL=true
    SHOW_FIREWALL_RULES=false
    SHOW_UPDATES=false
fi
COLOR_TITLE="\e[1;37m"; COLOR_LABEL="\e[0;36m"; COLOR_VALUE="\e[0;37m"
COLOR_GREEN="\e[0;32m"; COLOR_RED="\e[0;31m"; COLOR_YELLOW="\e[0;33m"
RESET="\e[0m"

safe_cmd() { local o; if o=\$("\$@" 2>/dev/null); then printf '%s' "\$o"; else printf 'N/A'; fi; }

show_logo() {
    if [[ "\$SHOW_LOGO" = true ]] && [[ -x "${TOILET}" ]]; then
        echo -e "\$COLOR_TITLE"
        "${TOILET}" -f standard "distillium" || echo "distillium"
        echo -e "\$RESET"
    fi
}
show_session_info() {
    echo -e "\$COLOR_TITLE• Session Info\$RESET"
    local u=\$(safe_cmd /usr/bin/logname)
    [[ "\$u" == N/A ]] && u=\$(who | awk 'NR==1{print \$1}')
    printf "\$COLOR_LABEL%-22s\$COLOR_YELLOW%s\$RESET\n" "User:" "\$u"
    local shown=false
    if command -v lastlog2 >/dev/null; then
        local o=\$(safe_cmd lastlog2 show -u "\$u" | tail -n1)
        if [[ "\$o" != N/A && -n "\$o" ]]; then printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Last login:" "\$o"; shown=true; fi
    fi
    if [[ \$shown == false && -f /var/lib/wtmpdb/wtmp.db ]] && command -v sqlite3 >/dev/null; then
        local w=\$(safe_cmd sqlite3 /var/lib/wtmpdb/wtmp.db "SELECT strftime('%F %T', time, 'unixepoch'),host FROM wtmp WHERE user='\$u' AND type=7 ORDER BY time DESC LIMIT 1;")
        if [[ -n "\$w" && "\$w" != N/A ]]; then printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Last login:" "\$w"; shown=true; fi
    fi
    if [[ \$shown == false && -f /var/log/lastlog && -x "${LASTLOG}" ]]; then
        local o=\$(safe_cmd "${LASTLOG}" -u "\$u" | tail -n1)
        [[ "\$o" != N/A ]] && printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Last login:" "\$o"
    fi
    local up=\$(safe_cmd "${UPTIME}" -p | sed 's/up //')
    printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Uptime:" "\$up"
}
show_system_info() {
    echo -e "\n\$COLOR_TITLE• System Info\$RESET"
    local h=\$(safe_cmd "${HOSTNAME}")
    printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Hostname:" "\${h:-Unknown}"
    local os=""
    if [[ -x "${LSB_RELEASE}" ]]; then
        os=\$(safe_cmd "${LSB_RELEASE}" -ds)
    elif [[ -f "/etc/os-release" ]]; then
        os=\$(safe_cmd "${GREP}" PRETTY_NAME /etc/os-release | "${CUT}" -d= -f2 | tr -d '"')
    else
        os="Unknown"
    fi
    printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "OS:" "\$os"
    local ipv4 ipv6
    if [[ -x "${IP}" ]]; then
        ipv4=\$(safe_cmd "${IP}" -4 addr show scope global | "${AWK}" '/inet/ {print \$2}' | "${CUT}" -d/ -f1 | "${HEAD}" -n1)
        ipv6=\$(safe_cmd "${IP}" -6 addr show scope global | "${AWK}" '/inet6/ {print \$2}' | "${CUT}" -d/ -f1 | "${HEAD}" -n1)
    fi
    printf "\$COLOR_LABEL%-22s\$COLOR_YELLOW%s\$RESET\n" "External IP (v4):" "\${ipv4:-N/A}"
    printf "\$COLOR_LABEL%-22s\$COLOR_YELLOW%s\$RESET\n" "External IP (v6):" "\${ipv6:-N/A}"
    local k=\$(safe_cmd "${UNAME}" -r)
    printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Kernel:" "\${k:-Unknown}"
}
bar() {
    local used=\$1 total=\$2 width=30
    [[ ! "\$used" =~ ^[0-9]+$ ]] || [[ ! "\$total" =~ ^[0-9]+$ ]] || [[ "\$total" -eq 0 ]] && { printf "[%-${width}s] N/A" ""; return; }
    local percent=\$((100 * used / total))
    local filled=\$((width * used / total))
    local empty=\$((width - filled))
    local color
    if [[ "\$percent" -lt 50 ]]; then color="\$COLOR_GREEN"; elif [[ "\$percent" -lt 80 ]]; then color="\$COLOR_YELLOW"; else color="\$COLOR_RED"; fi
    printf "["
    for ((i=0; i<filled; i++)); do printf "\$color"'━'; done
    for ((i=0; i<empty; i++)); do printf "\$RESET"'━'; done
    printf "\$RESET] %d%%" "\$percent"
}
show_cpu_info() {
    [[ "\$SHOW_CPU" = "true" ]] || return
    echo -e "\n\$COLOR_TITLE• CPU\$RESET"
    local cpu=\$(safe_cmd "${GREP}" -m1 "model name" /proc/cpuinfo | "${CUT}" -d: -f2 | "${SED}" 's/^ //')
    printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Model:" "\${cpu:-Unknown}"
    local idle usage
    if [[ -x "${VMSTAT}" ]]; then
        idle=\$(safe_cmd "${VMSTAT}" 1 2 | "${TAIL}" -1 | "${AWK}" '{print \$15}')
        [[ "\$idle" =~ ^[0-9]+$ ]] && usage=\$((100-idle)) || usage="N/A"
    else usage="N/A"; fi
    printf "\$COLOR_LABEL%-22s" "Usage:"; [[ "\$usage" != "N/A" ]] && bar "\$usage" 100 || printf "N/A"; echo
    local load=\$(safe_cmd "${AWK}" '{print \$1 " / " \$2 " / " \$3}' /proc/loadavg)
    printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Load average:" "\${load:-Unknown}"
}
show_memory_info() {
    [[ "\$SHOW_MEM" = "true" ]] || return
    echo -e "\n\$COLOR_TITLE• RAM & Disk\$RESET"
    if [[ -x "${FREE}" ]]; then
        local t u
        t=\$(safe_cmd "${FREE}" -m | "${AWK}" '/Mem:/ {print \$2}')
        u=\$(safe_cmd "${FREE}" -m | "${AWK}" '/Mem:/ {print \$3}')
        printf "\$COLOR_LABEL%-22s" "RAM:"; [[ "\$t" =~ ^[0-9]+$ && "\$u" =~ ^[0-9]+$ ]] && bar "\$u" "\$t" || printf "N/A"; echo
    fi
    if [[ -x "${DF}" ]]; then
        local u t
        u=\$(safe_cmd "${DF}" -m / | "${AWK}" 'NR==2{print \$3}')
        t=\$(safe_cmd "${DF}" -m / | "${AWK}" 'NR==2{print \$2}')
        printf "\$COLOR_LABEL%-22s" "Disk:"; [[ "\$t" =~ ^[0-9]+$ && "\$u" =~ ^[0-9]+$ ]] && bar "\$u" "\$t" || printf "N/A"; echo
    fi
}
show_network_info() {
    [[ "\$SHOW_NET" = "true" ]] && [[ -x "${IP}" ]] || return
    echo -e "\n\$COLOR_TITLE• Network\$RESET"
    local iface=\$(safe_cmd "${IP}" route get 8.8.8.8 2>/dev/null | "${AWK}" '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}')
    if [[ -n "\$iface" && -f "/sys/class/net/\$iface/statistics/rx_bytes" ]]; then
        local rx tx
        rx=\$(safe_cmd "${CAT}" "/sys/class/net/\$iface/statistics/rx_bytes")
        tx=\$(safe_cmd "${CAT}" "/sys/class/net/\$iface/statistics/tx_bytes")
        local units=('B' 'KB' 'MB' 'GB' 'TB') ru=0 tu=0
        while (( rx > 1024 && ru < 4 )); do rx=\$((rx / 1024)); ((ru++)); done
        while (( tx > 1024 && tu < 4 )); do tx=\$((tx / 1024)); ((tu++)); done
        printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Interface:" "\$iface"
        printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s \$\${units[\$ru]}\$RESET\n" "Received:" "\$rx"
        printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s \$\${units[\$tu]}\$RESET\n" "Transmitted:" "\$tx"
    else
        printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Network:" "Interface not found"
    fi
}
show_firewall_info() {
    [[ "\$SHOW_FIREWALL" = "true" ]] || return
    echo -e "\n\$COLOR_TITLE• Firewall\$RESET"
    local ufw_bin="/usr/sbin/ufw"
    if [[ -x "\$ufw_bin" ]]; then
        local status=\$(safe_cmd "\$ufw_bin" status | "${HEAD}" -1 | "${AWK}" '{print \$2}')
        if [[ "\$status" = active ]]; then
            printf "\$COLOR_LABEL%-22s\$COLOR_GREEN%s\$RESET\n" "UFW Status:" "\$status"
        else
            printf "\$COLOR_LABEL%-22s\$COLOR_RED%s\$RESET\n" "UFW Status:" "\${status:-inactive}"
        fi
    else
        printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "UFW:" "not installed"
    fi
}
show_docker_info() {
    [[ "\$SHOW_DOCKER" = "true" && -x "${DOCKER}" ]] || { [[ "\$SHOW_DOCKER" = "true" ]] && echo -e "\n\$COLOR_TITLE• Docker\$RESET\n\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Docker:" "not installed"; return; }
    echo -e "\n\$COLOR_TITLE• Docker\$RESET"
    local rn tn
    rn=\$(safe_cmd "${DOCKER}" ps --format '{{.Names}}' | "${WC}" -l)
    tn=\$(safe_cmd "${DOCKER}" ps -a --format '{{.Names}}' | "${WC}" -l)
    printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Containers:" "\$rn / \$tn"
    if [[ "\$rn" -gt 0 ]]; then
        echo -e "\$COLOR_LABEL Running Containers:\$RESET"
        safe_cmd "${DOCKER}" ps --format '{{.Names}}' | awk 'NR%2{printf "  \033[0;37m%-30s", \$0} NR%2==0{print \$0"\033[0m"}'
    fi
}
show_updates_info() {
    [[ "\$SHOW_UPDATES" = "true" ]] || return
    echo -e "\n\$COLOR_TITLE• Updates Available\$RESET"
    if command -v apt >/dev/null; then
        local uc=\$(apt list --upgradable 2>/dev/null | "${GREP}" -v "Listing" | "${WC}" -l)
        if [[ "\$uc" =~ ^[0-9]+$ && "\$uc" -gt 0 ]]; then
            printf "\$COLOR_LABEL%-22s\$COLOR_YELLOW%s packages\$RESET\n" "Total updates:" "\$uc"
            if [[ -x /usr/lib/update-notifier/apt-check ]]; then
                local sc=\$(/usr/lib/update-notifier/apt-check 2>&1 | "${CUT}" -d';' -f2)
                [[ "\$sc" =~ ^[0-9]+$ && "\$sc" -gt 0 ]] && printf "\$COLOR_LABEL%-22s\$COLOR_RED%s security\$RESET\n" "Security updates:" "\$sc"
            fi
            echo -e "\$COLOR_LABEL Run 'sudo apt upgrade' to install updates\$RESET"
        else
            printf "\$COLOR_LABEL%-22s\$COLOR_GREEN%s\$RESET\n" "Status:" "System is up to date"
        fi
    else
        printf "\$COLOR_LABEL%-22s\$COLOR_VALUE%s\$RESET\n" "Updates:" "apt not available"
    fi
}

main() {
    show_logo
    show_session_info
    show_system_info
    show_cpu_info
    show_memory_info
    show_network_info
    show_firewall_info
    show_docker_info
    show_updates_info
    echo
}
main
MOTD_EOF
    "${CHMOD}" 755 "${MOTD_SCRIPT}"
}

# ---------------------- Основной поток ----------------------
main() {
    check_root
    validate_system
    create_complete_directory_backup
    install_dependencies
    create_config
    create_motd_script
    log_info "Установка завершена успешно!"
    echo ""
    echo "========================================================="
    echo "             🎉 Кастомный MOTD установлен!"
    echo "========================================================="
    echo ""
    echo "📋 Доступные команды:"
    echo "  • motd         - Показать MOTD"
    echo "  • motd-set     - Настройки и управление"
    echo ""
    echo "💾 Полные бэкапы директорий: ${BACKUP_ROOT}"
    echo "🔄 Для удаления: motd-set -> Удалить"
    echo ""
}

main "$@"
