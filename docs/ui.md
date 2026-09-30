# UI 页面设计 v0.1（AI 可执行规格书）

> 日期：2026-09-30。**本文档是 UI 的唯一权威**，目标是：交给 AI 后可一次性生成全部 M1 页面，无需其他上下文。
> 配套：`manufacturing.md`（数据含义）、`design.md`（总系统）。
> 核心策略：**UI 与 sim 解耦**——所有页面通过 `DataProvider` 接口取数，当前用 `MockDataProvider`（假数据）生成，M0 sim 完成后只换实现不改页面。

---

## 1. 范围与页面清单

| ID | 页面 | 阶段 | 本版详细度 |
|---|---|---|---|
| P00 | 采矿 HUD（3D 场景叠加） | M2 | 简设（3D 场景由用户自建，HUD 做成独立可挂载场景） |
| P01 | 空间站总览（枢纽） | M1 | 详设 |
| P02 | 物流机库（泊位与来访货舰） | M1 | 详设 |
| P03 | 交易面板（选中货舰） | M1 | 详设（本作第一个核心页面） |
| P04 | 制造（建造厂） | M1 | 详设 |
| P05 | 研究站 | M1 | 详设 |
| P06 | 建造与升级 | M1 | 详设 |
| P07 | 库存仓库 | M1 | 详设 |
| P08 | 公司总览 | M1 | 详设 |
| P09 | 市场挂单 | M1 | 中等详设 |
| P10–P14 | 合约 / 战局图 / 议会 / 帝国采购局 / 会战结算 | M3+ | 占位一句话（§8） |

## 2. 全局架构约定

- 基准分辨率 1920×1080，全屏 Control + anchors，1280×720 下不得塌版
- **Shell + Page 架构**：站内所有页面共享 `StationShell.tscn`（TopBar + 底部导航 + 内容槽），页面是插进内容槽的子场景
- 每页脚本继承 `BasePage`（提供 `data: DataProvider` 与 `refresh()`；provider 发 `state_changed` 信号，页面连接后自动刷新）
- **一切数值来自 DataProvider，页面内禁止硬编码数值**（文案除外）
- 文件结构：

```
res://ui/
  theme/main_theme.gd          # 代码构建 Theme（token 见 §4）
  data_provider.gd             # 接口定义（§6）
  mock/mock_data.gd            # 假数据实现（含每日自动推进模拟）
  components/                  # TopBar, BottomNav, ItemSlot, QuantityPicker,
                               # ShipCard, ProgressLine, ConfirmDialog, EmptyState
  pages/
    hud_mining.tscn/.gd        # P00（CanvasLayer，挂进 3D 场景）
    station_shell.tscn/.gd
    p01_overview.tscn/.gd
    p02_hangar.tscn/.gd
    p03_trade.tscn/.gd
    p04_manufacturing.tscn/.gd
    p05_research.tscn/.gd
    p06_construction.tscn/.gd
    p07_storage.tscn/.gd
    p08_company.tscn/.gd
    p09_market.tscn/.gd
```

## 3. 导航图

```
3D 采矿场景 ──[HUD P00 常驻]──[返回空间站]
     │ 回站（转场；玩家不操舰，无驾驶元素）
     ▼
StationShell ─ P01 空间站总览（默认页）
     ├ 底部导航：总览 P01 │ 机库 P02 │ 制造 P04 │ 研究站 P05 │ 建造 P06 │ 库存 P07 │ 公司 P08 │ 市场 P09
     ├ P02 ──[点击停靠货舰]──► P03 交易面板
     ├ TopBar 右上[出站] ──► 回 3D 采矿场景
     └ Esc ──► 确认菜单（继续/出站/保存）
```

## 4. 主题规范（token）

工业深色风：细边框、小圆角、克制用色、数字用等宽。

| Token | 值 | 用途 |
|---|---|---|
| bg | #0D1117 | 页面底 |
| panel | #161B22 | 面板/卡片 |
| panel_hover | #1C2430 | 悬停 |
| border | #30363D | 1px 描边 |
| text | #E6EDF3 | 主文字 |
| text_dim | #8B949E | 次文字 |
| accent | #E8A33D | 琥珀主强调（按钮/选中/进度） |
| info | #58A6FF | 链接/信息 |
| ok | #3FB950 | 成功/盈利 |
| warn | #D29922 | 警告/缺料 |
| danger | #F85149 | 禁止/亏损 |
| 字号 | 标题 22 / 正文 16 / 小字 13 | |
| 圆角 4 / 间距 8·16·24 栅格 | | StyleBoxFlat 统一 |

## 5. 共享组件

| 组件 | 职责 |
|---|---|
| TopBar | 资金（等宽字体）/ 游戏日 / 燃料库存 / 通知铃铛 / 出站按钮 |
| BottomNav | 8 个页签按钮，当前页高亮 accent |
| ItemSlot | 图标位+名称+数量，可带缺料红框（warn 边框） |
| QuantityPicker | 数量输入：-/+ 步进、滑条、Max、确认；校验上下限 |
| ShipCard | 货舰卡：型号/隶属/舱容条(used/capacity)/剩余资金/走私标记 |
| ProgressLine | 单行进度：名称 + 进度条 + 剩余时间 |
| ConfirmDialog | 通用确认（标题/正文/确认回调） |
| EmptyState | 空状态占位（如"泊位空闲——等待下一艘货舰…"） |

## 6. 数据契约：DataProvider 接口

```gdscript
# res://ui/data_provider.gd —— UI 只准通过它取数/操作
signal state_changed

# ── 公司全局 ──
func get_credits() -> int
func get_game_day() -> int
func get_fuel_stock() -> int
func get_company_stage() -> Dictionary          # {index, name, next_goal}

# ── 物品与库存 ──
func get_item_def(id: String) -> Dictionary     # {id,name,category,tier,unit_value,icon}
func get_all_items() -> Array                   # 全部物品定义
func get_inventory() -> Dictionary              # {item_id: qty}
func get_ore_stock() -> Dictionary              # 仅矿石分类便捷读取

# ── 空间站 ──
func get_station_modules() -> Array             # {id,name,level,count,max,effects_desc,buildable}
func is_smuggler_allowed() -> bool
func set_smuggler_allowed(v: bool) -> void
func get_construction_options() -> Array        # 可新建模块 {id,name,cost:{item:qty},time}
func get_upgrade_options() -> Array             # 可升级项 {module_id,kind,next_effect,cost}
func get_construction_queue() -> Array          # 进行中 {module_id,progress,total}
func start_construction(module_id: String) -> Dictionary   # {ok,reason}

# ── 机库与货舰 ──
func get_berths() -> Array                      # 泊位数组，元素=null 或货舰字典
func get_ship(id: String) -> Dictionary         # {id,ship_class,hold_capacity,hold_used,credits,buys,sells,is_smuggler}
func sell_to_ship(ship_id: String, item_id: String, qty: int) -> Dictionary  # {ok,reason,moved,earned}
func buy_from_ship(ship_id: String, item_id: String, qty: int) -> Dictionary # {ok,reason,moved,cost}

# ── 制造 ──
func get_recipes() -> Array                     # {id,item_id,bom:{item:qty},time,needs_license,my_license_uses}
func get_production_lines() -> Array            # {index,busy,recipe_id,progress,total}
func start_production(recipe_id: String, line_index: int) -> Dictionary

# ── 研究 ──
func get_research_slots() -> Array              # 槽位数组 {busy,kind,target,progress}
func get_reverse_progress() -> Dictionary       # {device_id: {level,needed}}
func get_blueprints() -> Array                  # {id,item_id,is_original,me,te,me_max,te_max,t2_unlocked}
func start_research(bp_id: String, kind: String) -> Dictionary  # kind: "me"/"te"/"t2"

# ── 市场（P09）──
func get_market_orders(region_id: String) -> Array   # {id,item_id,qty,price,side,owner}
func place_order(side: String, item_id: String, qty: int, price: float) -> Dictionary
func get_my_orders() -> Array
```

Mock 要求：静态合理数值 + 每次调用 `advance_day()` 推进一天（生产/研究/建造进度+，来船轮换），让页面"活"起来便于自查。

## 7. 页面详设

### P00 采矿 HUD（3D 叠加，CanvasLayer）

- **玩家不操舰**：HUD 无任何驾驶/舱容元素（2026-09-30 拍板，见 manufacturing.md §7）
- 布局：左下＝携带量条+已采矿物列表（按稀有度着色）；中下＝采矿工具状态（进度环由 3D 场景发信号）；右上＝空间站方向指示与距离；左上＝当前引导目标一句话
- 稀有矿反馈：挖到"低概率"矿种时 HUD 闪特殊提示（稀有度感知=挖矿爽点）
- 快捷键提示条（底部小字）：采矿 / 返回空间站 / 详情——具体键位由 3D 场景定，HUD 只做显示
- 数据源：`get_inventory()`（过滤矿石）、`get_fuel_stock()`（提示燃料存量——燃料断供=卖不出去）；其余（采矿进度/瞄准）走 3D 场景信号，不在本契约内
- 验收：独立场景可挂任意 3D demo；数值随 mock 变化

### P01 空间站总览（枢纽）

```
┌──────────────────────────────────────────────┐
│ TopBar                                        │
├───────────┬──────────────────────────────────┤
│ 左栏 240px│ 模块卡片网格（2×2）               │
│ 公司摘要   │ [物流机库 L1 泊位1/1] [建造厂 ×0] │
│ ·阶段进度 │ [研究站 L0]        [货柜 ×0]      │
│ ·资金曲线 │ 每卡：名称/等级/效果一句话/进入按钮│
│ 库存摘要   │ ──────────────────────           │
│ ·矿石 Top5│ ＋ 建造新模块 → P06               │
├───────────┴──────────────────────────────────┤
│ BottomNav                                     │
└──────────────────────────────────────────────┘
```

- 数据源：`get_company_stage() get_credits() get_station_modules() get_inventory() get_fuel_stock()`
- 交互：卡片点击→对应页；"建造新模块"→P06

### P02 物流机库

```
┌──────────────────────────────────────────────┐
│ 机库头：等级 L1 | 泊位 1/1 | [走私停靠: 关 ⃝]  │
├──────────────────────────────────────────────┤
│ 泊位区（横向卡片流）                           │
│ [ShipCard: 小型工业运输舰 | 零点物流 |         │
│   舱容 ▓▓░ 137/400 | 资金 ₡12,400]            │
│ [EmptyState: 泊位空闲——下一艘 3 小时后]        │
├──────────────────────────────────────────────┤
│ 选中货舰 → 内嵌 P03 交易面板                   │
└──────────────────────────────────────────────┘
```

- 走私开关：切换弹 ConfirmDialog，文案列收益与代价（§manufacturing 5.4）
- 数据源：`get_berths() get_ship() is_smuggler_allowed() set_smuggler_allowed()`
- 交互：点击 ShipCard → 右侧/下方加载 P03

### P03 交易面板（核心页）

```
┌──────────────────────────────────────────────┐
│ 货舰头：型号|隶属|舱容 137/400|剩余资金 ₡12,400│
├──────────────────────┬───────────────────────┤
│ 卖出（站→船，占舱容） │ 买入（船货单→站）      │
│ 站内可售列表：        │ 货舰货单：             │
│ 生铁陨矿 ×320 @₡2.1  │ [许可证] 小型武器×30次 ₡450│
│  [100][Max][装入]    │ 结构桁架 ×8 @₡180      │
│ 装舱进度 ▓▓▓░137/400 │  [购买]                │
├──────────────────────┴───────────────────────┤
│ 成交记录（滚动，本次停靠累计）                  │
└──────────────────────────────────────────────┘
```

- 硬约束全部视觉化：舱满→卖出按钮禁用+tooltip"船舱已满"；资金尽→"货舰资金不足"；站内缺货→数量上限=库存
- 每笔交易调 `sell_to_ship/buy_from_ship`，返回 `{ok,reason}`，失败弹 toast（用 ConfirmDialog 变体或状态条）
- 数据源：`get_ship() get_inventory() sell_to_ship() buy_from_ship()`
- 验收：装满→离站→泊位变 EmptyState→新船到港（mock 推进）

### P04 制造（建造厂）

```
┌──────────────────────────────────────────────┐
│ 顶：生产线状态条 N 条 [空闲|舰炮弹药 34%]      │
├──────────────────────┬───────────────────────┤
│ 产品列表（分类 Tab： │ 选中产品详情：          │
│ 组件/小型产品/舰船）  │ BOM 表（缺料红字+差量）│
│ 每项：名称|BOM 摘要| │ 工期|许可证需求与余额  │
│ 工期|可造绿点/缺料黄 │ [开始生产]（选空闲线） │
├──────────────────────┴───────────────────────┤
│ 底：我的许可证库存（产品→剩余次数）             │
└──────────────────────────────────────────────┘
```

- 缺料时"开始生产"禁用+tooltip 列所缺物料
- 数据源：`get_recipes() get_production_lines() start_production() get_inventory()`

### P05 研究站

- 顶：研究槽 N 条（`get_research_slots()`，占用显示进度）
- Tab 逆向：设备列表＋逆向进度条（x/10）＋[指派到空闲槽]（满槽禁用）
- Tab 原图蓝图：蓝图卡（ME x/10、TE x/10）；按钮 [研究 ME] [研究 TE]；[解锁 T2] 为**占位禁用按钮**（T2 暂不设计，manufacturing.md §4.4），tooltip 写"科技路线规划中"
- 数据源：`get_reverse_progress() get_blueprints() start_research() get_research_slots()`

### P06 建造与升级

- Tab 新建模块：模块卡（配方：矿石+组件，缺料红标）＋[建造]
- Tab 升级：每模块一行（当前等级/叠加数→下一级效果预览＋成本）＋[升级]
- Tab 站务：走私停靠开关（同 P02，两处同一数据源）；风险说明
- 底：进行中建造队列（ProgressLine 列表）
- 数据源：`get_station_modules() get_construction_options() get_upgrade_options() start_construction() get_construction_queue()`

### P07 库存仓库

- 左分类树：矿石/燃料/空间站组件/小型产品/舰船/许可证/设备；右表格：名称|数量|参考单价|备注
- 燃料独立置顶区块（库存+日消耗预估）
- 数据源：`get_all_items() get_inventory() get_fuel_stock()`

### P08 公司总览

- 资金曲线（近 30 游戏日，简单折线自绘）；资产汇总（模块等级/泊位/蓝图数/许可证余额）；每日盈亏表（mock 记账）；阶段进度卡（阶段 0 拍荒者→下一目标）
- 数据源：`get_credits() get_company_stage() get_station_modules() get_blueprints()` + mock 账本

### P09 市场挂单（M1，中等详设）

- 左：订单簿（卖单列表：商品|数量|单价|距你星区）；右：我的挂单＋[撤单]
- 下单面板：买/卖切换、QuantityPicker、限价输入、手续费提示（费率来自 mock 常量）
- 与 P03 货舰报价并排可看价差——为"搬砖"玩法留入口
- 数据源：`get_market_orders() place_order() get_my_orders()`

## 8. 后续页面占位（M3+，本版不生成）

| ID | 一句话 |
|---|---|
| P10 合约 | 私下委托列表/创建/履约（保密属性标记） |
| P11 战局图 | 星区地图+前线+紧张度+缺口热力（工业仪表盘） |
| P12 议会 | 南联议题列表/影响力/投票 |
| P13 帝国采购局 | 好感度/合约等级/特许申请 |
| P14 会战结算 | 供应分面板："你供了 X，占 Y 阵营 Z%" |

## 9. 生成顺序与验收

**生成顺序**：theme → data_provider + mock → components → StationShell → P01 → P02 → P03 → P06 → P07 → P04 → P05 → P08 → P09 → P00 → 导航接线 → 自查遍历。

**全局验收（每页都要过）**：
1. 场景可独立打开运行，无报错、无缺失节点警告
2. 全部数据经 DataProvider，页面零硬编码数值
3. 主题 token 全局生效，页面无私自调色
4. 1280×720 与 1920×1080 布局均不塌
5. 所有按钮有反馈（视觉+可日志）；禁用态必须给原因 tooltip
6. 空状态用 EmptyState，不留白板

## 10. 长程任务指令模板（直接粘给 AI）

```text
任务：按 docs/ui.md 一次性生成《第二十一席》全部 M1 UI 页面（Godot 4.7.1 / GDScript）。

先读：docs/ui.md（唯一 UI 权威）、docs/manufacturing.md §5（数据含义）。
规则：
1. 数据一律走 res://ui/data_provider.gd 定义的接口，先实现 mock/mock_data.gd，页面内禁止硬编码数值。
2. 主题 token 按 ui.md §4，代码构建 Theme 并应用于 StationShell 与 P00。
3. 严格按 ui.md §9 顺序生成；每页完成即对照 §9 全局验收自检，不过关不进下一页。
4. 不修改 3D 采矿场景；P00 做成独立 CanvasLayer 场景供挂载。
5. 全部完成后：写一个临时遍历脚本依次打开每页各截图一张，自查布局塌陷与空状态，发现问题就地修复后再收尾。
交付：res://ui/ 全部场景+脚本、临时自查截图清单、与 ui.md 的差异说明（如有偏离必须写明原因）。
```

## 变更日志
- 2026-09-30 v0.1 初版：P00–P09 详设/中设，P10–P14 占位；DataProvider 契约 + Mock 策略 + 生成指令模板。
- 2026-09-30 v0.2 制造系统定稿同步：P00 去驾驶元素（玩家不操舰，运输全 NPC），导航图改"返回空间站"，P05 T2 按钮改占位禁用。
