# Account 页面 & 匿名登录设计

## 概述

为 Type4Me Cloud (Member 版) 新增完整的 Account 页面，替代当前散落在侧边栏底部和 CloudSettingsCard 中的账户信息展示。同时新增匿名登录 (用户名+密码)，与现有邮箱验证码登录并列，降低用户使用门槛。通过设备绑定防止免费额度滥用。

## 动机

- 当前账户信息分散在 `SidebarEditionCard` (紧凑预览) 和 `CloudSettingsCard` (详细信息) 两处，没有统一的入口
- 邮箱登录对部分用户门槛较高，需要更轻量的注册方式
- 缺少账单历史展示
- 需要设备级别的防刷机制保护免费额度

## 术语

| 术语 | 含义 |
|------|------|
| Member 版 | 使用 Type4Me Cloud 服务的版本 (edition == .member) |
| BYO API 版 | 用户自带 API Key 的版本 (edition == .byoKey) |
| 匿名登录 | 用户名+密码注册/登录，无需邮箱 |
| 设备 ID | macOS Hardware UUID (IOPlatformUUID)，硬件级别唯一标识 |

## 一、侧边栏布局改造

### 当前结构

```
├─ "TYPE4ME" 品牌头
├─ Nav tabs (General, Models, Vocabulary, Modes, History, About)
├─ Spacer
└─ SidebarEditionCard (紧凑的账户预览 + 版本切换)
```

### 新结构

```
├─ "TYPE4ME" 品牌头
├─ Nav tabs (General, [Models], Vocabulary, Modes, History, About)
├─ Spacer
├─ Account tab (样式与其他 nav item 一致，位于底部)
└─ 版本切换入口 (一行链接，如 "切换到自带 API →")
```

### 实现

- `SettingsTab` 枚举新增 `.account` case
- `.account` 不加入 `tabs(for:)` 返回值，在侧边栏底部手动渲染
- 样式复用现有 `navItem()` 方法 (SettingsView 内部 private 方法，因为在同一 struct 内渲染所以可以直接调用)
- 版本切换入口保留 `SidebarEditionCard` 现有的切换逻辑，简化为一行链接
- `SidebarEditionCard` 的紧凑账户预览功能移入 Account tab，卡片本身移除
- **可见性**: Account tab 仅在 `edition == .member` 时显示; BYO API 模式下不显示 (BYO 用户不需要 Cloud 账户)

## 二、Account 页面

### 未登录状态

页面展示两种登录方式:

**邮箱登录 (上方，推荐):**
- 复用现有 `CloudSettingsCard` 的邮箱验证码流程
- 邮箱输入 → 发送验证码 → 输入验证码 → 登录成功

**匿名模式 (下方):**
- 说明文案: "不想提供邮箱? 设置用户名和密码即可"
- 用户名输入框 + 密码输入框 (SecureField) + 注册按钮
- 密码要求: 最少 6 位，客户端 + 服务端双重校验，不满足时按钮禁用并显示提示
- 用户名冲突: 服务端返回 409，客户端显示 "用户名已被占用"
- 已有匿名账户的用户: 用户名 + 密码 → 登录

### 已登录状态

分为四个区块:

**1. 个人信息**
- 头像 (首字母) + 邮箱或用户名 + 状态 badge (免费/已订阅)
- 匿名用户额外显示 "绑定邮箱" 入口
- 提示: "请牢记用户名和密码，未绑定邮箱将无法找回"

**2. 订阅**
- 套餐: Free / Weekly
- 免费用户: 剩余字数 (1200 / 2000)，低于 500 显示橙色
- 付费用户: 到期日期
- 订阅按钮 (价格根据区域自动显示)

**3. 用量统计**
- 本周用量 (字数)
- 总计用量 (字数)

**4. 账单历史**
- 付款记录列表: 日期 | 金额 | 状态
- 加载中: 显示 ProgressView spinner
- 加载失败: 显示 "加载失败，点击重试"
- 无记录时显示 "暂无账单记录"

**底部:**
- 登出按钮 (signOut 需清除所有状态: JWT、email、user_id、username、loginMethod)

### 账单数据管理

`AccountTab` 内部直接管理账单数据，不新建 singleton manager (数据只在这个页面用):

```swift
// AccountTab 内部
@State private var billingRecords: [BillingRecord] = []
@State private var billingLoading = false
@State private var billingError: String?

struct BillingRecord: Decodable, Identifiable {
    let id: Int
    let amount: Int           // 分
    let currency: String      // "CNY" / "USD"
    let status: String        // "completed" / "refunded"
    let description: String?  // "周订阅"
    let created_at: String    // ISO8601
}
```

### 涉及文件

| 操作 | 文件 |
|------|------|
| 新建 | `Type4Me/UI/Settings/AccountTab.swift` |
| 修改 | `Type4Me/UI/Settings/SettingsView.swift` (侧边栏布局 + tab 枚举) |
| 修改 | `Type4Me/UI/Settings/SidebarEditionCard.swift` (简化为版本切换链接) |
| 修改 | `Type4Me/Auth/CloudAuthManager.swift` (新增 username/loginMethod/signOut 清理) |
| 可删除 | `Type4Me/UI/Settings/CloudSettingsCard.swift` (功能合并到 AccountTab) |

## 三、CloudAPIClient 统一请求层

### 问题

当前各组件 (`CloudQuotaManager`, `CloudASRClient` 等) 各自拼装 HTTP 请求，没有统一的 header 注入和错误处理。设备绑定需要每个请求都带 `X-Device-ID`，设备互踢需要统一拦截 401。不能让每个调用点单独处理。

### 设计

新建 `CloudAPIClient` 单例，所有 Cloud API 调用统一经过它:

```swift
@MainActor
final class CloudAPIClient {
    static let shared = CloudAPIClient()

    /// 发起认证请求，自动注入 Authorization + X-Device-ID headers
    /// 401 时自动区分错误类型并处理设备互踢
    func request(_ endpoint: String, method: String = "GET", body: Data? = nil) async throws -> Data

    /// 设备 ID (Hardware UUID，启动时缓存)
    let deviceID: String
}
```

**职责:**
- 自动注入 `Authorization: Bearer {jwt}` 和 `X-Device-ID: {hardwareUUID}` headers
- 拦截所有 401 响应，根据 error code 区分:
  - `device_conflict`: 设备被踢，调用 `CloudAuthManager.shared.signOut()`，发 Notification 通知 UI 显示提示
  - `token_expired`: JWT 过期，同上
  - `invalid_credentials`: 登录凭证错误，抛出具体错误让调用方处理
- `CloudQuotaManager.refresh()` 改为通过 `CloudAPIClient` 发请求
- 其他 Cloud API 消费者同理

**WebSocket 连接 (ASR):**
- WebSocket 不支持自定义 headers，device_id 通过 URL query param 传递: `wss://api.../asr?token={jwt}&device_id={uuid}`
- 服务端 WebSocket handler 从 query param 提取并校验

**服务端错误响应格式:**

```json
// 设备互踢
{"error": "device_conflict", "message": "Account logged in on another device"}

// JWT 过期
{"error": "token_expired", "message": "Token expired"}

// 凭证错误 (登录时)
{"error": "invalid_credentials", "message": "Invalid username or password"}

// 用户名冲突 (注册时，HTTP 409)
{"error": "username_taken", "message": "Username already exists"}
```

### 涉及文件

| 操作 | 文件 |
|------|------|
| 新建 | `Type4Me/Auth/CloudAPIClient.swift` |
| 修改 | `Type4Me/Auth/CloudQuotaManager.swift` (改用 CloudAPIClient) |
| 修改 | `Type4Me/ASR/CloudASRClient.swift` (WebSocket URL 加 device_id param) |

## 四、匿名登录

### 客户端

**CloudAuthManager 扩展:**

```swift
enum LoginMethod: String {
    case email
    case anonymous
}

// 新增属性
@Published private(set) var username: String?
@Published private(set) var loginMethod: LoginMethod?

// 新增方法
func registerAnonymous(username: String, password: String) async throws
func loginWithPassword(username: String, password: String) async throws
func bindEmail(email: String) async throws  // 发验证码
func confirmBindEmail(code: String) async throws  // 验证并绑定
```

- `username`、`loginMethod` 存 UserDefaults (`tf_cloud_username`、`tf_cloud_login_method`)
- 登录成功后和邮箱登录走同样的 JWT 存储路径
- `signOut()` 需清除: `tf_cloud_jwt`, `tf_cloud_email`, `tf_cloud_user_id`, `tf_cloud_username`, `tf_cloud_login_method`

### 服务端

**新增 API:**

| 端点 | 方法 | 请求体 | 说明 |
|------|------|--------|------|
| `/auth/register` | POST | `{username, password, device_id}` | 匿名注册，返回 JWT |
| `/auth/login` | POST | `{username, password, device_id}` | 用户名密码登录，返回 JWT |
| `/auth/bind-email` | POST | `{email}` (auth) | 给匿名账户发绑定验证码 |
| `/auth/confirm-bind` | POST | `{code}` (auth) | 确认绑定邮箱 |
| `/api/billing/history` | GET | (auth) | 返回付款记录列表 |

**现有端点修改:**

| 端点 | 变更 |
|------|------|
| `/auth/send-code` | 请求体新增 `device_id` 字段 |
| `/auth/verify` | 请求体新增 `device_id` 字段 |

**安全措施:**

- `/auth/login` rate limiting: 同一 username 连续 5 次失败 → 锁定 15 分钟; 同一 IP 每分钟最多 20 次
- `/auth/register` 校验 device_id 的已注册账户数
- 密码要求: 最少 6 位，服务端独立校验 (不信任客户端)
- 密码存储: bcrypt (cost factor 12)
- 绑定邮箱时校验邮箱唯一性，冲突时返回错误
- 用户名冲突: 返回 HTTP 409 + `{"error": "username_taken"}`

### 数据库变更

**`users` 表新增字段:**

```sql
ALTER TABLE users ADD COLUMN username TEXT UNIQUE;
ALTER TABLE users ADD COLUMN password_hash TEXT;
ALTER TABLE users ADD COLUMN login_method TEXT NOT NULL DEFAULT 'email';
```

- 邮箱用户: `email` 有值，`username` / `password_hash` 为 NULL
- 匿名用户: `username` + `password_hash` 有值，`email` 初始为 NULL

**新建 `billing_history` 表:**

```sql
CREATE TABLE billing_history (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id UUID NOT NULL REFERENCES users(id),
    amount INTEGER NOT NULL,          -- 金额 (分)
    currency TEXT NOT NULL,            -- "CNY" / "USD"
    provider TEXT,                     -- "paddle" / "lemonsqueezy"
    external_id TEXT,                  -- 支付平台订单 ID
    status TEXT NOT NULL DEFAULT 'completed',  -- completed / refunded
    description TEXT,                  -- "周订阅" 等
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_billing_history_user ON billing_history(user_id);
```

- Paddle/LemonSqueezy webhook 处理时同步写入 billing_history

## 五、设备绑定

### 目的

防止用户通过反复注册新账户获取免费额度 (2000 字/账户)。

### 设备 ID 获取

使用 macOS Hardware UUID (IOPlatformUUID):

```swift
import IOKit

func hardwareUUID() -> String? {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPlatformExpertDevice")
    )
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(
        service, "IOPlatformUUID" as CFString,
        kCFAllocatorDefault, 0
    )?.takeRetainedValue() as? String
}
```

特性:
- 硬件级别，重装系统/app 不变
- 无需权限或 entitlement
- 用户无法篡改 (除非换主板)

**兜底策略:** 如果 `IOPlatformUUID` 返回 nil (极少见，可能在 VM 或特殊硬件配置下)，则生成随机 UUID 存入 Keychain (`com.type4me.device-id`)。Keychain 在重装 app 时不会丢失，能提供次优的设备标识。启动时优先取 Hardware UUID，取不到才读 Keychain。

### 绑定规则

1. 一台设备最多绑定 1 个邮箱账户 + 1 个匿名账户
2. 一个账户同时只能在一台设备上活跃
3. 在新设备登录 → 旧设备 session 自动失效 (API 返回 401)
4. 不换设备的话，session 永不过期

### 服务端实现

**新建 `device_bindings` 表:**

```sql
CREATE TABLE device_bindings (
    device_id TEXT NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id),
    login_method TEXT NOT NULL,       -- "email" / "anonymous"
    bound_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (device_id, login_method)
);
```

**`users` 表新增字段:**

```sql
ALTER TABLE users ADD COLUMN active_device_id TEXT;
```

**校验逻辑:**

- 注册/登录时: 写入 `active_device_id`，检查 `device_bindings` 中同 device_id + login_method 的记录数
- API 中间件: 比对请求 header 中的 `X-Device-ID` 与 `active_device_id`，不匹配返回 401
- 客户端收到 401 后清除本地登录状态，提示 "账户已在其他设备登录"

### JWT 策略

- 签发有效期 1 年 (安全性由设备绑定保障，不依赖 JWT 过期)
- 邮箱登录和密码登录统一有效期
- 注意: `CloudAuthManager.swift` 中 JWT 存储注释需更新，原注释说 "short-lived"，改为标注安全性由设备绑定保障

## 六、数据流

### 匿名注册流程

```
用户输入用户名+密码 → 点击注册
  ↓
客户端: POST /auth/register {username, password, device_id}
  ↓
服务端: 检查 username 唯一性
        检查 device_id 的匿名账户数 (≤1)
        bcrypt(password) → password_hash
        创建 users 记录 (login_method='anonymous')
        创建 user_plans 记录 (plan='free', free_chars_remaining=2000)
        写入 device_bindings
        签发 JWT (exp=1年)
  ↓
客户端: 存 JWT + username + loginMethod → UserDefaults
        CloudAuthManager 更新 @Published 状态
        UI 切换到已登录视图
```

### 设备互踢流程

```
用户在设备 B 登录 (已在设备 A 活跃)
  ↓
服务端: active_device_id 更新为 设备 B
  ↓
设备 A 下次 API 请求:
  服务端比对 X-Device-ID ≠ active_device_id → 返回 401
  ↓
设备 A 客户端: 清除登录状态，提示 "账户已在其他设备登录"
```

## 七、不做的事

- **区域设置**: 后台自动检测，不在 Account 页面展示。如果自动检测出问题 (如 VPN 环境)，后续可在 General 设置中加手动覆盖
- **充值功能**: 后续单独设计
- **账户合并**: 匿名用户绑定邮箱时如果邮箱已被占用，直接报错，不做合并
- **密码找回**: 未绑定邮箱的匿名用户无法找回，by design
- **多设备同时在线**: 不支持，一个账户同时只能一台设备
