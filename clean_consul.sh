#!/bin/bash

# 交互式输入Consul地址
read -p "请输入Consul服务器地址（示例: localhost:8500）: " CONSUL_SERVER
CONSUL_SERVER=${CONSUL_SERVER:-"localhost:8500"}

# 交互式配置IP映射表
declare -A CONSUL_IP_MAP
echo "配置Consul节点IP映射（输入格式：节点名 IP，输入done结束）"
while true; do
  read -p "节点名与IP > " NODE IP
  [[ "$NODE" == "done" ]] && break
  [[ -n "$NODE" && -n "$IP" ]] && CONSUL_IP_MAP[$NODE]=$IP || \
  echo "格式错误！正确示例: consul-0 10.244.5.112"
done

# 选择运行模式
read -p "启用模拟模式吗？(true/false，默认true): " DRY_RUN
DRY_RUN=${DRY_RUN:-"true"}
until [[ "$DRY_RUN" =~ ^(true|false)$ ]]; do
  read -p "无效输入！请重新输入(true/false): " DRY_RUN
done

# 获取服务列表并过滤consul服务
SERVICES=$(curl -sS "http://$CONSUL_SERVER/v1/catalog/services" | jq -r 'keys[] | select(. != "consul")')

# 主处理逻辑
for SERVICE in $SERVICES; do
  echo -e "\n检查服务: \033[34m$SERVICE\033[0m"
  INSTANCES_RAW=$(curl -sS "http://$CONSUL_SERVER/v1/catalog/service/$SERVICE")
  
  # 处理空实例情况
  if [[ $(echo "$INSTANCES_RAW" | jq '. | length') -eq 0 ]]; then
    echo "该服务无注册实例"
    continue
  fi

  echo "$INSTANCES_RAW" | jq -c '.[]' | while read -r INSTANCE; do
    NODE=$(echo "$INSTANCE" | jq -r '.Node')
    SERVICE_ID=$(echo "$INSTANCE" | jq -r '.ServiceID')
    
    # 健康检查验证
    CHECK_RAW=$(curl -sS "http://$CONSUL_SERVER/v1/health/checks/$SERVICE")
    HAS_CHECK=$(echo "$CHECK_RAW" | jq --arg N "$NODE" --arg ID "$SERVICE_ID" '
      if (. | length) == 0 then false
      else any(.[]; .Node == $N and .ServiceID == $ID) end
    ')
    
    if [[ $HAS_CHECK == "false" ]]; then
      TARGET_IP=${CONSUL_IP_MAP[$NODE]:-$CONSUL_SERVER%:*}  # 自动提取IP
      DEREGISTER_URL="http://${TARGET_IP%%:*}:8500/v1/agent/service/deregister/$SERVICE_ID"
      
      # 执行控制
      if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "待执行命令: \033[33mcurl -X PUT '$DEREGISTER_URL'\033[0m"
      else
        echo -e "执行中: \033[31m$DEREGISTER_URL\033[0m"
        curl -X PUT -sS "$DEREGISTER_URL"
      fi
    fi
  done
done

echo -e "\n操作完成！\033[32m(模拟模式: $DRY_RUN)\033[0m"
