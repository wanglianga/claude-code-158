# 城市餐厨废油回收预约称重联单合规追踪服务（cityoil-trace）

面向城市餐厨废油回收监管场景的一体化后端服务：餐饮商户提交回收预约 → 回收公司按车辆容量/路线/商圈限行/处置厂接收窗口派单 → 司机到店扫码核验（商户、油桶编号、称重设备、现场照片、交接人）→ 出店称重进入电子联单并同步运输轨迹 → 处置厂二次称重比对（出店重量、运输损耗、到厂重量、桶数）→ 回收证明与结算，形成**来源—称重—运输—接收—异常说明**的合规闭环。

司机、商户、处置厂、监管端读取**同一份电子联单**（哈希版本链，逐版可校验，直接改库也会被发现），电子联单既是结算依据也是合规凭证，任何一方都不能另存一套口径。

## 技术栈

- Java 17、Spring Boot 3.3、Spring Data JPA、Bean Validation
- PostgreSQL（生产/kafka profile）或 H2 PostgreSQL 兼容模式（本地默认，零外部依赖）
- Kafka（kafka profile；默认使用进程内事件总线，事件同样落库审计）
- Maven

## 本地启动

### 方式一：零依赖快速启动（默认 local profile，H2 + 内存事件总线）

```bash
mvn spring-boot:run
# 或
mvn -q package -DskipTests
java -jar target/cityoil-trace-1.0.0.jar
```

服务启动在 http://localhost:8080 ，启动时自动建表并写入演示账号与档案。
H2 控制台：http://localhost:8080/h2-console （JDBC URL `jdbc:h2:mem:cityoil`，用户名 `sa`，空密码）。

### 方式二：PostgreSQL + Kafka（kafka profile）

```bash
docker compose up -d postgres kafka      # 启动依赖
mvn spring-boot:run -Dspring-boot.run.profiles=kafka
# 或整体容器化
docker compose up -d --build
```

Kafka topic 为 `cityoil-events`；关键领域事件先落 `domain_events` 表，再发送 Kafka，发送失败可按未发布记录补偿重投。

## 测试账号（种子数据）

| 角色 | 用户名 | 密码 | 说明 |
|---|---|---|---|
| 监管部门 | `regulator` | `reg123` | 市城管局监管员 |
| 回收公司 | `company` | `co123` | 绿源废油回收有限公司 |
| 司机 | `driver1` / `driver2` | `dr123` | 挂靠绿源公司 |
| 处置厂 | `plant1` | `pl123` | 中基生物柴油处置厂（有资质，接收 08:00–17:00） |
| 商户 | `merchant1` / `merchant2` / `merchant3` | `m123` | 川香阁 / 老街口火锅（在限行商圈 CORE_A）/ 和风拉面 |

认证：`POST /api/auth/login` 返回 token；之后所有业务接口携带
`Authorization: Bearer <token>`（token 为 base64(`username:password`)，演示用）。

## 核心业务流程与接口

完整接口路径见各 `@RestController`（`src/main/java/com/cityoil/trace/web/`），主要端点：

1. **商户** `/api/merchant`：提交预约（门店、桶数、预计重量、存放位置、营业时段、联系人）、临时取消、看板（回收证明/结算/月度趋势）、提出重量质疑、确认结算。
2. **回收公司** `/api/company`：待派预约、车辆余量、`dispatches/plan`（试规划不落库）、`dispatches`（确认派单并生成每站点电子联单）、效率看板（里程/站点/装载率/准时率）、争议复核、异常闭环、结算付款、设备上下线。
3. **司机** `/api/driver`：出发、到店登记（自动判晚点）、扫码核验、出店称重（设备自动 / 离线人工补录双人复核）、轨迹上报、到厂、爽约登记、拒收后续处置登记。
4. **处置厂** `/api/plant`：二次称重与接收/拒收（可登记混入厨余桶号）、闭环出具回收证明并生成结算单。
5. **监管** `/api/regulator`：合规流向看板、联单与版本链校验、抽查（版本链+四要素核验）、风险名单分析/扫描/解除、争议终局仲裁、异常与事件时间线。
6. **统一联单** `/api/manifests/{id}`：五方按权限读取同一份联单（含每桶、双称、异常、全部版本哈希）。

派单规划同时满足四个约束：车辆额定载重（容量贪心）、最近邻路线与时间推演、核心商圈早晚高峰货车限行避让、处置厂接收时间窗口（不可达可 `force=true` 强制并留痕告警）。

## 异常场景如何闭环

| 异常 | 系统行为 |
|---|---|
| 商户临时取消 | 派单前取消直接关闭；派单后取消释放车辆容量并开 `MERCHANT_CANCEL` 工单，公司须改派 |
| 司机迟到 | 实际到店晚于计划时间+宽限期（默认15分钟）自动开 `DRIVER_LATE`，计入准时率 KPI，但不断合规链路 |
| 油桶混入厨余 | 处置厂按桶标记，整单拒收或部分拒收，开 `KITCHEN_WASTE_MIXED`/`PLANT_REJECT`，登记退回/转交处置后才能结单 |
| 称重设备离线 | 核验时登记 `DEVICE_OFFLINE`；自动称重被拒，必须人工补录且填写商户现场复核人（双人留痕），补录后异常闭环 |
| 司机手动补录 | `MANUAL_ENTRY` 工单自动生成并标记已闭环，记录操作人、复核人、备注 |
| 运输轨迹缺失 | 全程无 GPS 点开 `TRACK_MISSING`，**阻断闭环**，须公司说明（如卡口视频佐证）并闭环 |
| 处置厂拒收 | 拒收联单不能正常闭环，须登记后续处置结果 |
| 商户质疑重量 | 联单置 `DISPUTED`、结算冻结；公司复核或监管仲裁，认可则版本链追加 `WEIGHT_CORRECTED` 并重算结算 |
| 监管抽查 | 抽查单核验版本链完整性与“出店称重/运输轨迹/到厂称重/接收决定”四要素，结论回写 |
| 运输损耗超限 | 超硬上限（默认10%）开 `LOSS_EXCEEDED` 阻断闭环；超告警阈值（5%）留痕 |

## 长期趋势与风险名单

每次预约/闭环写入 `merchant_monthly_stats`。监管可对单户或全量扫描（默认近 6 个月，最少 3 个月）：
- 实际月均回收量 / 按营业规模测算的理论月均产量 < 40%，或
- 实际月均回收次数 / 理论频次 < 50%，或窗口内零回收

即进入风险名单（MEDIUM/HIGH），记录比值、窗口与原因；恢复合理后再次分析会自动解除。

## 电子联单版本链（四方共一账）

- 关键动作（`VERIFIED / WEIGHED_OUT / TRACK_VERIFIED / RECEIVED / DISPUTE_RAISED / WEIGHT_CORRECTED / CLOSED / REJECTION_HANDLED`）各追加一版不可变记录。
- `hash = SHA-256(prevHash | seq | 规范化JSON快照)`，链头为创世 64 个 0。
- 校验接口除重算哈希外，还会把 **CLOSED 版本快照中的出店/到厂重量、桶数、结算净重与当前联单字段逐项比对**：直接改数据库会返回 `-1` 断链标记。
- 回收证明出具时记录联单链头哈希，与联单绑定。

## 本地验证方式

```bash
# 1. 全量自动化测试（27 个用例：24 个端到端集成 + 2 个 Kafka 发布器单元 + 1 个嵌入式 Kafka 真实收发）
mvn test

# 2. 启动后用 curl 走一遍真实 HTTP 全链路（见下）
mvn spring-boot:run
```

快速冒烟脚本（另见仓库根目录 `smoke.sh`，会驱动预约→派单→核验→称重→轨迹→到厂→闭环并校验版本链）：

```bash
./smoke.sh
```

关键手工验证点：
- `GET /api/regulator/dashboard`：`closedManifests`、`flowToQualifiedPlantRatio=100`、异常分布。
- `GET /api/manifests/{id}`：`chainBrokenAt: []` 表示链完整；直接 SQL 改 `manifests.inbound_total_kg` 后再查，会返回 `[-1]`。
- 设备置离线后自动称重返回 422；`manual=true` 且无 `reviewer` 也返回 422。

## 工程结构

```
src/main/java/com/cityoil/trace/
├── domain/      JPA 实体与枚举（预约/派单/油桶/联单/版本链/称重/轨迹/异常/接收/争议/抽查/证明/结算/月统计/风险/事件）
├── repo/        Spring Data 仓储
├── service/     预约、派单规划、联单作业、哈希链、争议、结算、风控、抽查、查询看板、事件发布
├── event/       EventPublisher（InMemoryEventPublisher / KafkaEventPublisher 双实现）
├── security/    Bearer 认证拦截器与角色隔离
├── web/         五类角色 REST 接口
└── config/      配置属性、Web 配置、种子数据
src/test/java/   27 个测试（真实 Spring 容器 + MockMvc + H2 的端到端集成，及嵌入式 Kafka 事件收发）
```
