#!/bin/bash

set -e

echo "[+] Installing dependencies..."
apt-get update -qq
apt-get install -y toilet figlet procps lsb-release whiptail > /dev/null

echo "[+] Disabling default MOTD scripts..."
find /etc/update-motd.d/ -type f -name "[0-9][0-9]-*" ! -name "00-remnawave" -exec chmod -x {} \; > /dev/null 2>&1

echo "[+] Creating MOTD config..."
CONFIG_FILE="/etc/rw-motd.conf"
cat <<EOF > "$CONFIG_FILE"
SHOW_LOGO=true
SHOW_CPU=true
SHOW_MEM=true
SHOW_NET=true
SHOW_DOCKER=true
SHOW_FIREWALL=true
EOF

echo "[+] Installing MOTD script..."
mkdir -p /etc/update-motd.d

cat << 'EOF' > /etc/update-motd.d/00-remnawave
#!/bin/bash
source /etc/rw-motd.conf

COLOR_TITLE="\e[1;37m"
COLOR_LABEL="\e[0;36m"
COLOR_VALUE="\e[0;37m"
COLOR_GREEN="\e[0;32m"
COLOR_RED="\e[0;31m"
COLOR_YELLOW="\e[0;33m"
BOLD="\e[1m"
RESET="\e[0m"

bar() {
  local USED=$1 TOTAL=$2 WIDTH=30
  local PERCENT=$((100 * USED / TOTAL))
  local FILLED=$((WIDTH * USED / TOTAL))
  local EMPTY=$((WIDTH - FILLED))
  local COLOR
  if [ $PERCENT -lt 50 ]; then COLOR="${COLOR_GREEN}"
  elif [ $PERCENT -lt 80 ]; then COLOR="${COLOR_YELLOW}"
  else COLOR="${COLOR_RED}"
  fi
  printf "["
  for ((i=0; i<FILLED; i++)); do printf "${COLOR}━"; done
  for ((i=0; i<EMPTY; i++)); do printf "${RESET}━"; done
  printf "${RESET}] %d%%" "$PERCENT"
}

[ "$SHOW_LOGO" = true ] && {
  echo -e "${COLOR_TITLE}"
  toilet -f standard "distillium"
  echo -e "${RESET}"
}

LAST_LOGIN=$(last -i -w $(whoami) | grep -v "still logged in" | grep -v "0.0.0.0" | grep -v "127.0.0.1" | sed -n 2p)
LAST_DATE=$(echo "$LAST_LOGIN" | awk '{print $4, $5, $6, $7}')
LAST_IP=$(echo "$LAST_LOGIN" | awk '{print $3}')

echo -e "${COLOR_TITLE}• Session Info${RESET}"

REAL_USER=$(logname 2>/dev/null || who | awk 'NR==1{print $1}')
printf "${COLOR_LABEL}%-22s${COLOR_YELLOW}%s${RESET}\n" "User:" "$REAL_USER"

if [ -f /var/log/lastlog ]; then
  LASTLOG_RAW=$(lastlog -u "$REAL_USER" | tail -n 1)
  LASTLOG_DATE=$(echo "$LASTLOG_RAW" | awk '{printf "%s %s %s %s %s", $4, $5, $6, $7, $9}')
  LASTLOG_IP=$(echo "$LASTLOG_RAW" | awk '{print $3}')
  printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s ${COLOR_YELLOW}from %s${RESET}\n" "Last login:" "$LASTLOG_DATE" "$LASTLOG_IP"
else
  echo -e "${COLOR_LABEL}Last login:${RESET} not available"
fi

UPTIME_FMT=$(uptime -p | sed 's/up //')
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Uptime:" "$UPTIME_FMT"

echo -e "\n${COLOR_TITLE}• System Info${RESET}"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Hostname:" "$(hostname)"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "OS:" "$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
printf "${COLOR_LABEL}%-22s${COLOR_YELLOW}%s${RESET}\n" "External IP:" "$(hostname -I | awk '{print $1}')"
printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Kernel:" "$(uname -r)"

[ "$SHOW_CPU" = true ] && {
  echo -e "\n${COLOR_TITLE}• CPU${RESET}"
  CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d ':' -f2 | sed 's/^ //')
  CPU_IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}')
  CPU_USAGE=$((100 - CPU_IDLE))
  LOAD_AVG=$(awk '{print $1 " / " $2 " / " $3}' /proc/loadavg)
  printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Model:" "$CPU_MODEL"
  printf "${COLOR_LABEL}%-22s" "Usage:"
  bar "$CPU_USAGE" 100
  echo
  printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Load average:" "$LOAD_AVG"
}

[ "$SHOW_MEM" = true ] && {
  echo -e "\n${COLOR_TITLE}• RAM & Disk${RESET}"
  MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
  printf "${COLOR_LABEL}%-22s" "RAM:"
  bar "$MEM_USED" "$MEM_TOTAL"
  echo
  DISK_USED=$(df -m / | awk 'NR==2{print $3}')
  DISK_TOTAL=$(df -m / | awk 'NR==2{print $2}')
  printf "${COLOR_LABEL}%-22s" "Disk:"
  bar "$DISK_USED" "$DISK_TOTAL"
  echo
}

[ "$SHOW_NET" = true ] && {
  echo -e "\n${COLOR_TITLE}• Network${RESET}"
  NET_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  if [ -n "$NET_IFACE" ]; then
    RX_BYTES=$(cat /sys/class/net/$NET_IFACE/statistics/rx_bytes)
    TX_BYTES=$(cat /sys/class/net/$NET_IFACE/statistics/tx_bytes)
    human_readable() {
      local BYTES=$1 UNITS=('B' 'KB' 'MB' 'GB' 'TB') UNIT=0
      while (( BYTES > 1024 && UNIT < 4 )); do BYTES=$((BYTES / 1024)); ((UNIT++)); done
      echo "${BYTES} ${UNITS[$UNIT]}"
    }
    RX_HR=$(human_readable $RX_BYTES)
    TX_HR=$(human_readable $TX_BYTES)
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Interface:" "$NET_IFACE"
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Received:" "$RX_HR"
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Transmitted:" "$TX_HR"
  else
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Network:" "Interface not found"
  fi
}

[ "$SHOW_FIREWALL" = true ] && {
  echo -e "\n${COLOR_TITLE}• Firewall${RESET}"
  if command -v ufw &>/dev/null; then
    STATUS=$(ufw status | head -1 | awk '{print $2}')
    if [ "$STATUS" = "active" ]; then
      printf "${COLOR_LABEL}%-22s${COLOR_GREEN}%s${RESET}\n" "UFW Status:" "$STATUS"
    else
      printf "${COLOR_LABEL}%-22s${COLOR_RED}%s${RESET}\n" "UFW Status:" "$STATUS"
    fi
  else
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "UFW:" "not installed"
  fi
}

[ "$SHOW_DOCKER" = true ] && {
  echo -e "\n${COLOR_TITLE}• Docker${RESET}"
  if command -v docker &>/dev/null; then
    RUNNING=$(docker ps -q | wc -l)
    TOTAL=$(docker ps -a -q | wc -l)
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Containers:" "$RUNNING / $TOTAL"
    if [ "$RUNNING" -gt 0 ]; then
      echo -e "${COLOR_LABEL}Running Containers:${RESET}"
      NAMES=($(docker ps --format '{{.Names}}'))
      for ((i = 0; i < ${#NAMES[@]}; i+=2)); do
        printf "  ${COLOR_VALUE}%-30s%-30s${RESET}\n" "${NAMES[$i]}" "${NAMES[$((i + 1))]}"
      done
    fi
  else
    printf "${COLOR_LABEL}%-22s${COLOR_VALUE}%s${RESET}\n" "Docker:" "not installed"
  fi
}

echo
EOF

chmod +x /etc/update-motd.d/00-remnawave

echo "[+] Setting MOTD symlinks..."
rm -f /etc/motd
ln -sf /var/run/motd /etc/motd
ln -sf /etc/update-motd.d/00-remnawave /usr/local/bin/rw-motd

echo "[+] Creating config menu 'rw-motd-set'..."
cat << 'EOF' > /usr/local/bin/rw-motd-set
#!/bin/bash
CONFIG="/etc/rw-motd.conf"
CHOICES=$(whiptail --title "MOTD Settings" --checklist \
"Выберите, что отображать в MOTD:" 20 60 10 \
"SHOW_LOGO" "Логотип distillium" $(grep -q 'SHOW_LOGO=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_CPU" "Загрузка процессора" $(grep -q 'SHOW_CPU=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_MEM" "Память и диск" $(grep -q 'SHOW_MEM=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_NET" "Сетевой трафик" $(grep -q 'SHOW_NET=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_FIREWALL" "Статус UFW" $(grep -q 'SHOW_FIREWALL=true' "$CONFIG" && echo ON || echo OFF) \
"SHOW_DOCKER" "Контейнеры Docker" $(grep -q 'SHOW_DOCKER=true' "$CONFIG" && echo ON || echo OFF) \
3>&1 1>&2 2>&3)

for VAR in SHOW_LOGO SHOW_CPU SHOW_MEM SHOW_NET SHOW_FIREWALL SHOW_DOCKER; do
  if echo "$CHOICES" | grep -q "$VAR"; then
    sed -i "s/^$VAR=.*/$VAR=true/" "$CONFIG"
  else
    sed -i "s/^$VAR=.*/$VAR=false/" "$CONFIG"
  fi
done

echo -e "[OK] Настройки обновлены. Проверь командой: \e[1mrw-motd\e[0m"
EOF

chmod +x /usr/local/bin/rw-motd-set

echo "[+] Configuring PAM and SSH for MOTD..."

for PAM_FILE in /etc/pam.d/sshd /etc/pam.d/login; do
  sed -i '/pam_motd.so motd=\/run\/motd.dynamic/d' "$PAM_FILE"
  grep -q "pam_motd.so noupdate" "$PAM_FILE" || \
    echo "session optional pam_motd.so noupdate" >> "$PAM_FILE"
done

SSHD_CONFIG="/etc/ssh/sshd_config"
grep -q "^PrintMotd" "$SSHD_CONFIG" && \
  sed -i 's/^PrintMotd.*/PrintMotd no/' "$SSHD_CONFIG" || \
  echo "PrintMotd no" >> "$SSHD_CONFIG"

grep -q "^PrintLastLog" "$SSHD_CONFIG" && \
  sed -i 's/^PrintLastLog.*/PrintLastLog no/' "$SSHD_CONFIG" || \
  echo "PrintLastLog no" >> "$SSHD_CONFIG"

for PAM_FILE in /etc/pam.d/sshd /etc/pam.d/login; do
  sed -i 's/^\(session.*pam_lastlog.so.*\)/#\1/' "$PAM_FILE"
done

if systemctl is-active ssh >/dev/null 2>&1; then
  systemctl reload ssh
elif systemctl is-active sshd >/dev/null 2>&1; then
  systemctl reload sshd
else
  echo "⚠️ Не удалось перезапустить SSH — перезапусти вручную"
fi

echo "[OK] Установка завершена!"
echo -e "[INFO] Используй \e[1mrw-motd\e[0m для ручного вызова, или \e[1mrw-motd-set\e[0m для настройки."
