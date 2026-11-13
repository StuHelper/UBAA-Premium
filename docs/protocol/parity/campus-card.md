# 校园卡充值

## 航财通数币钱包（2026-11-13）

冻结旧版 `1f4b8f8412272b6a423d4ad92b396e3db721e6f3` 和 buaa-api `a63712fa2ae0a6c8066197063ddee98e3a6b5b81` 都没有航财通、钱包、充值或订单协议；下表各业务操作九列对两个冻结来源均不适用。通用 CAS 对照旧版 `LocalConnectionAuth.kt`、`CasParser.kt`、`CasParserTest.kt`，及 buaa-api `src/api/sso/auth.rs`、`src/store/{cookies,cred}.rs`，继续使用 Core 的已有 SSO 会话，不由支付功能保存或提交密码。首页提示沿用[校园账户指标](campus.md#逐操作协议)，充值页余额走航财通。

证据来自同会话 Direct 浏览器、已观察的商城与收银台脚本及脱敏只读响应。Mall 指 `https://mall.cc-pay.cn`，Cashier 指 `https://cashier.cc-pay.cn`。普通商城请求接受 JSON 并附 `t`；收银台脚本使用 `version: v2`、JSON Accept 和 `_t==<毫秒>`。未见额外加密或签名。仅认可固定 HTTPS 来源与明确的跳转目的，禁止自动跟随支付跳转。

| 操作 | CAS/service | 跳转/最终 URL | Cookie、会话 | 方法和参数 | 头/正文 | 加密/签名 | DTO | 并发/缓存/重试 | 错误与产品含义 |
|---|---|---|---|---|---|---|---|---|---|
| 商城会话 | SSO `/login`，service=`https://pass.cc-pay.cn/login` | CAS 回调接收 ticket；浏览器最终落在 Mall `/`，未记录已认证请求的中间状态。Pass 登录地址也可能返回 HTML 外壳 | 复用 UBAA Direct SSO，业务 Cookie 用隔离容器并按域匹配 | GET | 导航，无正文 | 既有 SSO | 以随后的受保护 JSON 请求判定认证，HTML 本身不作为成功依据 | 有限跳转、单账号 | 业务失效不等于全局退出 |
| 充值项目 | 商城会话 | Mall `/api/payment_items` | 商城 | GET `pageSize=-1` | 商城 JSON | 无 | `type=200,success=true,data.data[]`，按 `code=buaa_campus_card_recharge` 取唯一有效 `id` | 在线动态取 ID | 没有有效项目时不写入 |
| 本人身份 | 同上 | Mall `/api/bill/note/feeInfo` | 商城 | GET `fromType=campus_card_fee` | 商城 JSON | 无 | `data.realName,stuNo` 字符串；仅用于本人订单 | 每次写入前读取 | 缺失或账号不匹配时停止 |
| 充值页余额 | 同上 | Pass `/api/campus_card/balance` | 航财通账户会话 | GET `stuNo=<当前已认证学工号>` | JSON Accept、`t` 时间戳 | 无 | `data.balance` 为元的十进制字符串；金额外的字段不跨出 Core | 进入或刷新充值页、付款后读取；首页刷新不访问此接口 | 失败显示未知，不用零值或门户缓存代替 |
| 已绑钱包设置 | 同上 | Pass `/api/bound_ec_tokens` | 航财通账户会话 | GET，无业务参数 | JSON Accept、`t` 时间戳 | 无 | `data[]` 中的 `nickName` 是账户页显示用银行代码，只投影未删除记录的该字段 | 页面按需读取；设置只保存选定银行代码 | 空数组表示无绑定，其他字段不保留 |
| 支付资格 | 同上 | Cashier `/api/pay_ways` | 收银台 | GET `payScene=`、`goodsId=<充值项目 id>`；实测无订单号可读 | 收银台 JSON | 无 | `data.ecCode` 银行代码数组；`data.normal` 中 `name=ecpay_token` 的字符串 `id` | 建单前校验所选钱包仍可用 | 不自动换钱包 |
| 建单与冲突 | 同上 | Mall `/api/payment` → `data.cashierUrl`（Cashier `/cashier?id=…`） | 商城 | POST JSON `targetId=mall_id,targetType=mall,money,itemId,feeInfo,fromType=campus_card_fee,choice=""`；`feeInfo` 是 `{stuNo,realName}` 的 JSON 字符串 | JSON UTF-8，金额以元的十进制 JSON 数字发送 | 无 | `type=200` 表示可前往收银台；`type=406,sub_type=4060003` 为旧单仍开着；`4060002` 为其他订单冲突 | 用户发起后最多一次 `choice=close-old`；其它情况不重放 | 不关闭其它订单；超时或意外响应先查交费记录 |
| 核对交易 | 同上 | Cashier `/transaction` | 收银台 | GET `id` | 收银台 JSON | 无 | `data.id,goodsId,money,currency,status,targetOrderId,returnUrl`；实测 `wait_payer_pay` 与 `success`，币种 `CNY`；回链为 Mall `/transaction_result?billId=…` | 扣款前核对交易，写后允许只读回读 | 商品、金额、状态不符时不扣款 |
| 数币扣款 | 同上 | Cashier `/transaction/pay` | 收银台 | GET `id,payWayId,phoneNumber=,ecCode`；虽为 GET，属于写入 | 收银台 JSON | 无 | 前端见 `success` 后开始核对商城结果 | 串行、单次、禁止传输或应用自动重放 | 响应不明确先回读同一单；状态仍不明时提示核对 |
| 支付结果 | 同上 | Mall `/api/check_pay_result/by_sys` | 商城 | GET `billId` | 商城 JSON | 无 | `data.id,note.feeInfo.paymentItemId,transactionId,money,fromType,status`；`1` 成功、`2` 已支付待同步、`0` 未支付、`3` 已关闭 | 有界只读回查，核对同一订单 | 状态 2 单独呈现；不得用余额涨幅推断付款结果 |

用户本人在收银台确认了一笔 0.10 元，Mall 显示支付成功；两个 1 元测试中的第二次建单复现 `4060003` 对应的冲突弹窗，未扣款。用户确认 UBAA 在这类冲突中选“关闭旧订单，创建新订单”。当前证据未验证 UBAA 发出的真实写请求和 WebVPN 的航财通链路；不得将浏览器成功算作生产入口或双路线验收。

航财通和收银台是公网服务。参考云盘的专用认证恢复，校园卡使用固定 Direct 恢复目标；即使全局采用 WebVPN，也只为当前账号补齐 Direct SSO，不变更全局配置。首页低余额提示继续遵守门户路线。WebVPN 模式下的组合场景仍需真实账号验证。
