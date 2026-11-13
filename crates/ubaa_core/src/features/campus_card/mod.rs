use serde_json::{Value, json};
use url::Url;

use crate::error::{ErrorCode, ErrorKind, Result, UbaaError};
use crate::ports::{HttpRequest, HttpResponse, same_url};
use crate::runtime::ClientRuntime;

const MALL: &str = "https://mall.cc-pay.cn";
const CASHIER: &str = "https://cashier.cc-pay.cn";
const PASS_ORIGIN: &str = "https://pass.cc-pay.cn";
const PASS: &str = "https://pass.cc-pay.cn/login";
const KIND: &str = "campus_card_fee";

pub(crate) fn auth_required() -> UbaaError {
    UbaaError::new(
        ErrorCode::AuthenticationRequired,
        ErrorKind::Authentication,
        false,
        "航财通需要有效的学校 SSO 会话，请重新登录后再试",
    )
}

fn invalid() -> UbaaError {
    UbaaError::upstream_changed("航财通返回了无法核对的校园卡信息")
}

fn unavailable(message: &'static str) -> UbaaError {
    UbaaError::new(
        ErrorCode::BusinessUnavailable,
        ErrorKind::Upstream,
        false,
        message,
    )
}

fn unknown() -> UbaaError {
    UbaaError::outcome_unknown("充值结果待核对。请先在航财通交费记录核对，避免重复付款")
}

fn yuan_cents(raw: &str) -> Option<u32> {
    let (whole, fraction) = raw.split_once('.').unwrap_or((raw, ""));
    if whole.is_empty()
        || !whole.bytes().all(|b| b.is_ascii_digit())
        || fraction.len() > 2
        || !fraction.bytes().all(|b| b.is_ascii_digit())
        || (raw.contains('.') && fraction.is_empty())
    {
        return None;
    }
    let fraction = match fraction.len() {
        0 => 0,
        1 => fraction.parse::<u32>().ok()? * 10,
        _ => fraction.parse().ok()?,
    };
    whole
        .parse::<u32>()
        .ok()?
        .checked_mul(100)?
        .checked_add(fraction)
}

fn amount(value: &Value) -> Option<u32> {
    if let Some(s) = value.as_str() {
        yuan_cents(s)
    } else {
        yuan_cents(&value.as_number()?.to_string())
    }
}

fn endpoint(origin: &str, path: &str) -> Url {
    Url::parse(&format!("{origin}{path}")).expect("固定航财通 URL")
}

fn trusted(url: &Url, host: &str, path: &str) -> bool {
    url.scheme() == "https"
        && url.host_str() == Some(host)
        && url.port().is_none()
        && url.path() == path
        && url.username().is_empty()
        && url.password().is_none()
        && url.fragment().is_none()
}

fn single_parameter(url: &Url, key: &str) -> Option<String> {
    let mut pairs = url.query_pairs();
    let (name, value) = pairs.next()?;
    (name == key && !value.is_empty() && value.len() <= 512 && pairs.next().is_none())
        .then(|| value.into_owned())
}

async fn navigate(runtime: &mut ClientRuntime, url: &Url) -> Result<HttpResponse> {
    let response = runtime
        .request_with_pre_send_check(
            HttpRequest::get(url.as_str()),
            ClientRuntime::ensure_session_revision,
        )
        .await?;
    runtime.ensure_session_revision()?;
    if !same_url(url.as_str(), &response.final_url) {
        return Err(invalid());
    }
    Ok(response)
}

pub(crate) async fn login(runtime: &mut ClientRuntime) -> Result<()> {
    let mut sso = endpoint("https://sso.buaa.edu.cn", "/login");
    sso.query_pairs_mut().append_pair("service", PASS);
    let callback = redirect(&sso, &navigate(runtime, &sso).await?)?;
    if !trusted(&callback, "pass.cc-pay.cn", "/login")
        || single_parameter(&callback, "ticket").is_none()
    {
        return Err(invalid());
    }
    let response = navigate(runtime, &callback).await?;
    // Pass also serves an HTML login shell at this URL. The next protected API
    // must validate the session; the shell itself says nothing about login.
    if response.status == 200 {
        return Ok(());
    }
    let home = redirect(&callback, &response)?;
    if !trusted(&home, "mall.cc-pay.cn", "/") || home.query().is_some() {
        return Err(invalid());
    }
    if navigate(runtime, &home).await?.status != 200 {
        return Err(auth_required());
    }
    Ok(())
}

fn redirect(base: &Url, response: &HttpResponse) -> Result<Url> {
    if response.status == 200 || matches!(response.status, 401 | 403) {
        return Err(auth_required());
    }
    if !matches!(response.status, 301 | 302 | 303 | 307 | 308) {
        return Err(invalid());
    }
    base.join(response.header_first("location").ok_or_else(invalid)?)
        .map_err(|_| invalid())
}

fn api_url(runtime: &ClientRuntime, origin: &str, path: &str, params: &[(&str, &str)]) -> Url {
    let mut url = endpoint(origin, path);
    let t = runtime
        .now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let mut q = url.query_pairs_mut();
    if origin == CASHIER {
        q.append_pair("_t", &format!("={t}"));
    } else {
        q.append_pair("t", &t.to_string());
    }
    q.extend_pairs(params);
    drop(q);
    url
}

fn api_headers(request: HttpRequest, cashier: bool) -> HttpRequest {
    let request = request.with_header("Accept", "application/json");
    if cashier {
        request.with_header("version", "v2")
    } else {
        request
    }
}

fn raw_json(response: &HttpResponse, expected: &str) -> Result<Value> {
    if !same_url(&response.final_url, expected) {
        return Err(invalid());
    }
    if matches!(response.status, 401 | 403) {
        return Err(auth_required());
    }
    if response.status != 200 && response.status != 406 {
        return Err(invalid());
    }
    let v: Value = serde_json::from_slice(&response.body).map_err(|_| invalid())?;
    if v["type"].as_u64() == Some(401) {
        return Err(auth_required());
    }
    Ok(v)
}

fn data(v: &Value) -> Result<&Value> {
    if v["type"].as_u64() == Some(200) && v["success"].as_bool() == Some(true) {
        return v.get("data").ok_or_else(invalid);
    }
    Err(invalid())
}

async fn read(
    runtime: &mut ClientRuntime,
    origin: &str,
    path: &str,
    params: &[(&str, &str)],
) -> Result<Value> {
    let url = api_url(runtime, origin, path, params);
    let response = runtime
        .request_with_pre_send_check(
            api_headers(HttpRequest::get(url.as_str()), origin == CASHIER),
            ClientRuntime::ensure_session_revision,
        )
        .await?;
    runtime.ensure_session_revision()?;
    let v = raw_json(&response, url.as_str())?;
    Ok(data(&v)?.clone())
}

fn identifier(v: &Value) -> Result<&str> {
    v.as_str()
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 128
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
        })
        .ok_or_else(invalid)
}

pub(crate) async fn item(runtime: &mut ClientRuntime) -> Result<String> {
    let result = read(runtime, MALL, "/api/payment_items", &[("pageSize", "-1")]).await?;
    let mut matches = result["data"]
        .as_array()
        .ok_or_else(invalid)?
        .iter()
        .filter(|r| {
            r["code"]
                .as_str()
                .is_some_and(|v| v.eq_ignore_ascii_case("buaa_campus_card_recharge"))
                && r["isActive"].as_bool() == Some(true)
        });
    let item = matches
        .next()
        .ok_or_else(|| unavailable("航财通当前没有可用的校园卡充值项目"))?;
    if matches.next().is_some() {
        return Err(invalid());
    }
    Ok(identifier(&item["id"])?.to_owned())
}

pub(crate) async fn balance(runtime: &mut ClientRuntime) -> Result<u32> {
    let student = runtime.account_name().ok_or_else(auth_required)?.to_owned();
    let result = read(
        runtime,
        PASS_ORIGIN,
        "/api/campus_card/balance",
        &[("stuNo", &student)],
    )
    .await?;
    result["balance"]
        .as_str()
        .and_then(yuan_cents)
        .ok_or_else(invalid)
}

pub(crate) async fn bound_wallets(runtime: &mut ClientRuntime) -> Result<Vec<String>> {
    let result = read(runtime, PASS_ORIGIN, "/api/bound_ec_tokens", &[]).await?;
    let mut codes = Vec::new();
    for row in result.as_array().ok_or_else(invalid)? {
        match row["isDeleted"].as_bool() {
            Some(true) => continue,
            Some(false) => {}
            None => return Err(invalid()),
        }
        let code = identifier(&row["nickName"])?;
        if !codes.iter().any(|existing| existing == code) {
            codes.push(code.to_owned());
        }
    }
    Ok(codes)
}

struct Wallets {
    codes: Vec<String>,
    pay_way: Option<String>,
}

async fn wallets(runtime: &mut ClientRuntime, item: &str) -> Result<Wallets> {
    let result = read(
        runtime,
        CASHIER,
        "/api/pay_ways",
        &[("payScene", ""), ("goodsId", item)],
    )
    .await?;
    let mut codes = Vec::new();
    if let Some(value) = result.get("ecCode").filter(|v| !v.is_null()) {
        for code in value.as_array().ok_or_else(invalid)? {
            let code = identifier(code)?.to_owned();
            if !codes.contains(&code) {
                codes.push(code);
            }
        }
    }
    let mut tokens = result["normal"]
        .as_array()
        .ok_or_else(invalid)?
        .iter()
        .filter(|v| v["name"].as_str() == Some("ecpay_token"));
    let pay_way = tokens
        .next()
        .map(|v| identifier(&v["id"]).map(str::to_owned))
        .transpose()?;
    if tokens.next().is_some() {
        return Err(invalid());
    }
    if pay_way.is_none() {
        codes.clear();
    }
    Ok(Wallets { codes, pay_way })
}

enum Order {
    Checkout(String),
    ReplaceOld,
}

fn order_response(v: &Value) -> Result<Order> {
    match (v["type"].as_u64(), v["sub_type"].as_u64()) {
        (Some(200), _) => {
            let url = Url::parse(data(v)?["cashierUrl"].as_str().ok_or_else(invalid)?)
                .map_err(|_| invalid())?;
            if !trusted(&url, "cashier.cc-pay.cn", "/cashier") {
                return Err(invalid());
            }
            let id = single_parameter(&url, "id").ok_or_else(invalid)?;
            identifier(&json!(id))?;
            Ok(Order::Checkout(id))
        }
        (Some(406), Some(4_060_003)) => Ok(Order::ReplaceOld),
        (Some(406), Some(4_060_002)) => Err(unavailable(
            "航财通有其他待支付订单，请到交费记录处理后再试",
        )),
        _ => Err(unknown()),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum BillOutcome {
    Paid,
    Syncing,
    Pending,
    Closed,
}

fn bill_outcome(v: &Value, bill: &str, item: &str, tx: &str, cents: u32) -> Result<BillOutcome> {
    if v["id"].as_str() != Some(bill)
        || v["note"]["feeInfo"]["paymentItemId"].as_str() != Some(item)
        || v["transactionId"].as_str() != Some(tx)
        || v["fromType"].as_str() != Some(KIND)
        || amount(&v["money"]) != Some(cents)
    {
        return Err(invalid());
    }
    match v["status"].as_str() {
        Some("0") => Ok(BillOutcome::Pending),
        Some("1") => Ok(BillOutcome::Paid),
        Some("2") => Ok(BillOutcome::Syncing),
        Some("3") => Ok(BillOutcome::Closed),
        _ => Err(invalid()),
    }
}

async fn write(runtime: &mut ClientRuntime, request: HttpRequest) -> Result<Value> {
    let url = request.url.clone();
    let response = runtime
        .request_non_idempotent_with_pre_send_check(
            request,
            ClientRuntime::check_authentication_scope,
        )
        .await?;
    runtime.ensure_session_revision().map_err(|_| unknown())?;
    raw_json(&response, &url).map_err(|_| unknown())
}

async fn create(
    runtime: &mut ClientRuntime,
    item: &str,
    cents: u32,
    identity: &Value,
) -> Result<String> {
    let url = api_url(runtime, MALL, "/api/payment", &[]);
    let money = serde_json::from_str::<Value>(&format!("{}.{:02}", cents / 100, cents % 100))
        .map_err(|_| invalid())?;
    for choice in ["", "close-old"] {
        let body = json!({"targetId":"mall_id","targetType":"mall","money":money,"itemId":item,
            "feeInfo":identity.to_string(),"fromType":KIND,"choice":choice});
        let request = api_headers(
            HttpRequest::post(url.as_str(), body.to_string().into_bytes()),
            false,
        )
        .with_header("Content-Type", "application/json;charset=UTF-8");
        let v = write(runtime, request).await?;
        match order_response(&v) {
            Ok(Order::Checkout(id)) => return Ok(id),
            Ok(Order::ReplaceOld) if choice.is_empty() => {}
            Ok(Order::ReplaceOld) => break,
            Err(error) if error.code == ErrorCode::BusinessUnavailable => return Err(error),
            Err(_) => return Err(unknown()),
        }
    }
    Err(unavailable("航财通仍有待支付订单，请到交费记录处理后再试"))
}

async fn verify_checkout(
    runtime: &mut ClientRuntime,
    tx: &str,
    item: &str,
    cents: u32,
) -> Result<String> {
    let details = read(runtime, CASHIER, "/transaction", &[("id", tx)]).await?;
    if details["id"].as_str() != Some(tx)
        || details["goodsId"].as_str() != Some(item)
        || amount(&details["money"]) != Some(cents)
        || details["currency"].as_str() != Some("CNY")
        || details["status"].as_str() != Some("wait_payer_pay")
    {
        return Err(unavailable(
            "航财通订单的金额、项目或状态无法核对，未发起扣款",
        ));
    }
    let url =
        Url::parse(details["returnUrl"].as_str().ok_or_else(invalid)?).map_err(|_| invalid())?;
    if !trusted(&url, "mall.cc-pay.cn", "/transaction_result") {
        return Err(invalid());
    }
    let bill = single_parameter(&url, "billId").ok_or_else(invalid)?;
    identifier(&json!(bill))?;
    if details["targetOrderId"].as_str() != Some(bill.as_str()) {
        return Err(invalid());
    }
    Ok(bill)
}

pub(crate) async fn recharge(
    runtime: &mut ClientRuntime,
    item: &str,
    cents: u32,
    wallet: &str,
) -> Result<BillOutcome> {
    let identity = read(
        runtime,
        MALL,
        "/api/bill/note/feeInfo",
        &[("fromType", KIND)],
    )
    .await?;
    let student = identity["stuNo"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(invalid)?;
    let name = identity["realName"]
        .as_str()
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(invalid)?;
    if Some(student) != runtime.account_name() {
        return Err(auth_required());
    }
    let available = wallets(runtime, item).await?;
    if !available.codes.iter().any(|code| code == wallet) {
        return Err(unavailable("选中的数币钱包已不可用，请重新选择"));
    }
    let pay_way = available.pay_way.ok_or_else(invalid)?;
    let tx = create(
        runtime,
        item,
        cents,
        &json!({"stuNo":student,"realName":name}),
    )
    .await?;
    let bill = verify_checkout(runtime, &tx, item, cents).await?;
    let url = api_url(
        runtime,
        CASHIER,
        "/transaction/pay",
        &[
            ("id", &tx),
            ("payWayId", &pay_way),
            ("phoneNumber", ""),
            ("ecCode", wallet),
        ],
    );
    // 无论支付端返回什么，成功与否以同一商城订单的只读状态为准。
    let _ = write(runtime, api_headers(HttpRequest::get(url.as_str()), true)).await;
    for delay in [0, 500, 1_000] {
        if delay != 0 {
            tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
        }
        if let Ok(result) = read(
            runtime,
            MALL,
            "/api/check_pay_result/by_sys",
            &[("billId", &bill)],
        )
        .await
        {
            match bill_outcome(&result, &bill, item, &tx, cents) {
                Ok(outcome @ (BillOutcome::Paid | BillOutcome::Syncing)) => return Ok(outcome),
                Ok(BillOutcome::Closed) => return Err(unavailable("航财通订单已关闭")),
                _ => {}
            }
        }
    }
    Err(unknown())
}

#[cfg(test)]
mod tests;
