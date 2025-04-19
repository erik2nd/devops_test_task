#!/bin/bash

set -e

if [ $# -ne 1 ]; then
  echo "Использование: $0 <ip1,ip2>"
  exit 1
fi

IFS=',' read -ra HOSTS <<< "$1"

SSH_KEY="~/.ssh/postgres_deploy_key"

get_load() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$1" "uptime | awk -F'load average:' '{print \$2}' | cut -d',' -f1 | xargs"
}

echo "Оценка загрузки серверов..."
min_load=1000
target_host=""
for host in "${HOSTS[@]}"; do
  load=$(get_load "$host")
  echo "  $host: $load"
  load_int=$(echo "$load" | awk '{print int($1+0.5)}')
  if (( $(echo "$load < $min_load" | bc -l) )); then
    min_load=$load
    target_host=$host
  fi
done

echo "Выбран сервер с наименьшей загрузкой: $target_host"

DISTRO=$(ssh -i "$SSH_KEY" root@"$target_host" "cat /etc/os-release | grep '^ID=' | cut -d'=' -f2 | tr -d '\"'")

echo "Дистрибутив целевого сервера: $DISTRO"
echo "Установка PostgreSQL..."

if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
  ssh -i "$SSH_KEY" root@"$target_host" bash -s <<'EOF'
set -e
apt-get update
apt-get install -y wget gnupg2 lsb-release
sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
apt-get update
apt-get install -y postgresql
EOF
elif [[ "$DISTRO" == "centos" || "$DISTRO" == "almalinux" || "$DISTRO" == "rhel" ]]; then
  ssh -i "$SSH_KEY" root@"$target_host" bash -s <<'EOF'
set -e
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %{rhel})-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf -qy module disable postgresql
dnf install -y postgresql15-server
/usr/pgsql-15/bin/postgresql-15-setup initdb
systemctl enable --now postgresql-15
EOF
else
  echo "Неизвестный дистрибутив: $DISTRO"
  exit 2
fi

echo "Настройка PostgreSQL для внешних подключений..."

if [[ "${HOSTS[0]}" == "$target_host" ]]; then
  other_host="${HOSTS[1]}"
else
  other_host="${HOSTS[0]}"
fi

PGDATA=$(ssh -i "$SSH_KEY" root@"$target_host" "su - postgres -c 'psql -t -c \"SHOW data_directory;\"' | xargs")

ssh -i "$SSH_KEY" root@"$target_host" "sed -i \"/^#listen_addresses/s/#listen_addresses = 'localhost'/listen_addresses = '*'/\" $PGDATA/postgresql.conf"

ssh -i "$SSH_KEY" root@"$target_host" "echo \"host    all    student    $other_host/32    md5\" >> $PGDATA/pg_hba.conf"

if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
  ssh -i "$SSH_KEY" root@"$target_host" "systemctl restart postgresql"
else
  ssh -i "$SSH_KEY" root@"$target_host" "systemctl restart postgresql-15"
fi

echo "Создание пользователя student..."
ssh -i "$SSH_KEY" root@"$target_host" "su - postgres -c \"psql -c \\\"DO \\\$\\\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'student') THEN CREATE ROLE student LOGIN PASSWORD 'studentpass'; END IF; END \\\$\\\$;\\\"\""

echo "Проверка подключения к БД и выполнение SELECT 1..."
ssh -i "$SSH_KEY" root@"$target_host" "su - postgres -c \"psql -c 'SELECT 1;'\""

echo "Готово. PostgreSQL установлен и настроен на $target_host"
