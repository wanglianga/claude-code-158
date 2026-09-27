#!/usr/bin/env bash
# 端到端冒烟：真实 HTTP 调用走通 预约→派单→核验→出店称重→轨迹→到厂二次称重→闭环，并校验版本链。
# 前置：服务已在 $BASE（默认 http://localhost:8080）启动，数据库为初始种子状态。
set -euo pipefail

BASE="${BASE:-http://localhost:8080}"
M="merchant1:m123"; CO="company:co123"; DR="driver1:dr123"; PL="plant1:pl123"; RG="regulator:reg123"

tok() { printf '%s' "$1" | base64; }
api() { # api METHOD PATH TOKEN [JSON_BODY]
  local method="$1" path="$2" token="$3" body="${4:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$BASE$path" -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -sS -X "$method" "$BASE$path" -H "Authorization: Bearer $token"
  fi
}

echo "== 0. 等待服务就绪 =="
for i in $(seq 1 60); do
  curl -sf "$BASE/api/health" >/dev/null 2>&1 && break
  sleep 2
done

TODAY=$(TZ=Asia/Shanghai date +%F)
echo "== 1. 商户提交预约（2 桶 / 预计 120kg） =="
APPT=$(api POST /api/merchant/appointments "$(tok "$M")" "{
  \"appointmentDate\":\"$TODAY\",\"barrelCount\":2,\"estimatedKg\":120,
  \"preferredStart\":\"${TODAY}T10:00:00+08:00\",\"preferredEnd\":\"${TODAY}T12:00:00+08:00\"}")
APPT_ID=$(echo "$APPT" | jq .id)
echo "appointmentId=$APPT_ID"
mapfile -t BARRELS < <(echo "$APPT" | jq -r '.barrels[].barrelNo')
echo "barrels=${BARRELS[*]}"

echo "== 2. 公司试规划（车辆1/司机1） =="
PLAN=$(api POST /api/company/dispatches/plan "$(tok "$CO")" "{
  \"vehicleId\":1,\"driverId\":1,\"appointmentIds\":[$APPT_ID],
  \"date\":\"$TODAY\",\"preferredDepartAt\":\"${TODAY}T10:00:00+08:00\"}")
echo "plant=$(echo "$PLAN" | jq -r '.plantName') 距离=$(echo "$PLAN" | jq -r '.totalDistanceKm')km 到厂=$(echo "$PLAN" | jq -r '.plannedArrivePlantAt')"
[ "$(echo "$PLAN" | jq -r '.totalStops')" = "1" ] || { echo "规划站点数错误"; exit 1; }

echo "== 3. 确认派单 =="
DISPATCH=$(api POST /api/company/dispatches "$(tok "$CO")" "{
  \"vehicleId\":1,\"driverId\":1,\"appointmentIds\":[$APPT_ID],
  \"date\":\"$TODAY\",\"preferredDepartAt\":\"${TODAY}T10:00:00+08:00\"}")
DISPATCH_ID=$(echo "$DISPATCH" | jq .id)
echo "dispatchId=$DISPATCH_ID $(echo "$DISPATCH" | jq -r .dispatchNo)"

echo "== 4. 司机出发 / 到店 =="
api POST "/api/driver/dispatches/$DISPATCH_ID/depart" "$(tok "$DR")" >/dev/null
api POST "/api/driver/dispatches/$DISPATCH_ID/arrive-stop" "$(tok "$DR")" "{\"appointmentId\":$APPT_ID}" >/dev/null

echo "== 5. 到店扫码核验（桶号/设备/照片/交接人） =="
api POST "/api/driver/appointments/$APPT_ID/verify" "$(tok "$DR")" "{
  \"scannedBarrelNos\":[\"${BARRELS[0]}\",\"${BARRELS[1]}\"],
  \"deviceCode\":\"DEV-MERCHANT1\",
  \"photos\":[\"site-01.jpg\",\"site-02.jpg\"],
  \"handoverPerson\":\"王经理\",\"handoverPhone\":\"13900000000\"}" | jq '{manifestNo,status,verifiedAt}'

echo "== 6. 出店称重（皮重5 毛重25，两桶净重共40kg） =="
api POST "/api/driver/appointments/$APPT_ID/weigh-out" "$(tok "$DR")" "{
  \"manual\":false,\"deviceCode\":\"DEV-MERCHANT1\",
  \"weights\":[
    {\"barrelNo\":\"${BARRELS[0]}\",\"tareKg\":5,\"grossKg\":25},
    {\"barrelNo\":\"${BARRELS[1]}\",\"tareKg\":5,\"grossKg\":25}
  ]}" | jq '{status,outboundBarrelCount,outboundTotalKg}'

echo "== 7. 同步运输轨迹 =="
api POST "/api/driver/dispatches/$DISPATCH_ID/track" "$(tok "$DR")" "{
  \"points\":[
    {\"lng\":120.13,\"lat\":30.31,\"speedKmh\":35,\"appointmentId\":$APPT_ID},
    {\"lng\":120.17,\"lat\":30.34,\"speedKmh\":40,\"appointmentId\":$APPT_ID}
  ]}" | jq .

echo "== 8. 到厂 =="
api POST "/api/driver/dispatches/$DISPATCH_ID/arrive-plant" "$(tok "$DR")" >/dev/null

MF_ID=$(api GET /api/regulator/manifests "$(tok "$RG")" \
  | jq ".[] | select(.appointmentId==$APPT_ID) | .id")
echo "manifestId=$MF_ID"

echo "== 9. 处置厂二次称重（毛重24.5，净重19.5/桶，共39kg，损耗1kg）并接收 =="
api POST "/api/plant/manifests/$MF_ID/receive" "$(tok "$PL")" "{
  \"weighbridgeCode\":\"WB-PLANT-01\",\"receiver\":\"厂区收料员\",
  \"inboundWeights\":[
    {\"barrelNo\":\"${BARRELS[0]}\",\"tareKg\":5,\"grossKg\":24.5},
    {\"barrelNo\":\"${BARRELS[1]}\",\"tareKg\":5,\"grossKg\":24.5}
  ],
  \"contaminatedBarrelNos\":[]}" | jq '{receiptNo,decision,acceptedBarrels,acceptedNetKg}'

echo "== 10. 闭环（出具回收证明 + 生成结算单） =="
api POST "/api/plant/manifests/$MF_ID/close" "$(tok "$PL")" | jq '{manifestNo,status,closedAt}'

echo "== 11. 监管校验版本链（intact 应为 true） =="
api GET "/api/regulator/manifests/$MF_ID/verify-chain" "$(tok "$RG")" | jq .

echo "== 12. 监管看板 =="
api GET /api/regulator/dashboard "$(tok "$RG")" \
  | jq '{totalManifests,closedManifests,totalInboundKg,closedSettlementKg,flowToQualifiedPlantRatio,openExceptions,activeRiskMerchants}'

echo "== 13. 商户看板（回收证明/结算） =="
api GET /api/merchant/dashboard "$(tok "$M")" \
  | jq '{certificates:[.certificates[]|{certificateNo,netKg,barrelCount}],
          settlements:[.settlements[]|{settlementNo,netKg,amount,status}]}'

echo "SMOKE OK：全链路闭环完成"
