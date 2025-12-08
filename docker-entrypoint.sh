#!/bin/bash

my_hostname=$(hostname)
my_ip=$(hostname -i)
export CONSUL_HTTP_ADDR=${ENV_CONSUL_HOST}:${ENV_CONSUL_PORT}

# MySQL 8: 减少 mysql CLI 噪音
mysql_exec="MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -N -s"

function mysql_running() {
  ss -lnt | grep -q ":3306 "
}

function get_read_only() {
  # MySQL 8: read_only & super_read_only 都会影响写入
  ro=$($mysql_exec -e "SELECT IF(@@global.super_read_only = 1 OR @@global.read_only = 1, 1, 0);")
  [[ "$ro" =~ ^[01]$ ]] || echo "-1"
  echo "$ro"
}

function register_service() {
  last_state="-1"

  while true; do
    if ! mysql_running; then
      echo "MySQL not running..."
      sleep 5
      continue
    fi

    ro=$(get_read_only)

    if [ "$ro" = "-1" ]; then
      echo "Invalid read_only value"
      sleep 5
      continue
    fi

    # 如果状态无变化
    if [ "$last_state" = "$ro" ]; then
      sleep 2
      continue
    fi

    # 状态发生变化，重新注册 Consul
    if [ "$ro" = "1" ]; then
      my_id="${my_hostname}.mysql-ro.${ENV_CLUSTER_NAMESPACE}.svc.cluster.local"
      my_name="mysql-ro.npool.top"
    else
      my_id="${my_hostname}.mysql.${ENV_CLUSTER_NAMESPACE}.svc.cluster.local"
      my_name="mysql.npool.top"
    fi

    consul services deregister -id="$my_id"

    consul services register \
      -address="$my_ip" \
      -port=3306 \
      -name="$my_name" \
      -id="$my_id"

    if [ $? -ne 0 ]; then
      echo "Failed to register $my_name"
      sleep 3
      continue
    fi

    last_state="$ro"
    echo "Registered service: $my_name (ro=$ro)"
    sleep 2
  done
}

function pmm_admin_add_mysql() {
  while true; do
    consul_pmm_service=$(curl -s "http://${CONSUL_HTTP_ADDR}/v1/agent/service/pmm.${ENV_CLUSTER_NAMESPACE}.svc.cluster.local")
    pmm_service=$(echo "$consul_pmm_service" | jq -r '.Service')
    pmm_port=$(echo "$consul_pmm_service" | jq -r '.Port')

    if [ "$pmm_port" = "443" ]; then
      echo "Detected PMM server: $pmm_service:$pmm_port"
      pmm-agent setup \
        --config-file=/usr/local/percona/pmm2/config/pmm-agent.yaml \
        --server-insecure-tls \
        --server-address="$pmm_service:$pmm_port" \
        --server-username=admin \
        --server-password="$ENV_PMM_ADMIN_PASSWORD" \
        --force >> /var/log/pmm-agent.log 2>&1

      pmm-agent run \
        --config-file=/usr/local/percona/pmm2/config/pmm-agent.yaml \
        --server-insecure-tls \
        --server-address="$pmm_service:$pmm_port" >> /var/log/pmm-agent.log 2>&1 &

    else
      echo "PMM server not registered yet"
      sleep 10
      continue
    fi

    break
  done

  pmm-admin status
  if [ $? -eq 0 ]; then
    while true; do
      if mysql_running; then
        echo "Registering MySQL into PMM…"
        pmm-admin add mysql --query-source=slowlog     --username=root --password="$MYSQL_ROOT_PASSWORD" sl-"$my_hostname"
        pmm-admin add mysql --query-source=perfschema  --username=root --password="$MYSQL_ROOT_PASSWORD" ps-"$my_hostname"
        break
      else
        echo "MySQL not running"
        sleep 5
      fi
    done
  else
    echo "PMM admin not running"
  fi
}

function set_sql_mode() {
  while true; do
    if mysql_running; then
      # MySQL 8: 通过 JSON SEARCH 替换 sql_mode 更安全
      current_mode=$($mysql_exec -e "SELECT @@global.sql_mode;")

      new_mode=$(echo "$current_mode" | sed 's/ONLY_FULL_GROUP_BY//g' | sed 's/,,/,/g' | sed 's/^,//' | sed 's/,$//')

      $mysql_exec -e "SET GLOBAL sql_mode='$new_mode';"
      echo "SQL_MODE updated: $new_mode"
      break
    else
      echo "MySQL not running"
      sleep 5
    fi
  done
}

register_service &
pmm_admin_add_mysql &
set_sql_mode &

exec /usr/local/bin/docker-entrypoint-inner.sh "$@"

