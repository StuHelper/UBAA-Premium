use serde_json::json;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use super::{BillOutcome, Order, bill_outcome, order_response, yuan_cents};
use crate::domain::ConnectionMode;
use crate::error::{ErrorCode, ErrorKind, Result, UbaaError};
use crate::ports::{HttpMethod, HttpRequest, HttpResponse, HttpTransport};
use crate::runtime::ClientRuntime;
use crate::session::{SessionMutation, SessionSnapshot, SessionStore, VersionedSession};

#[test]
fn amounts_are_exact_and_invalid_precision_is_rejected() {
    assert_eq!(yuan_cents("0.1"), Some(10));
    assert_eq!(yuan_cents("100.01"), Some(10_001));
    assert_eq!(yuan_cents("0.001"), None);
    assert_eq!(yuan_cents("1e2"), None);
}

#[test]
fn only_explicit_old_order_conflict_can_trigger_replacement() {
    assert!(matches!(
        order_response(&json!({"type":406,"sub_type":4_060_003})),
        Ok(Order::ReplaceOld)
    ));
    assert!(order_response(&json!({"type":406,"sub_type":4_060_002})).is_err());
    assert!(order_response(&json!({"type":500,"sub_type":4_060_003})).is_err());
    assert!(
        order_response(&json!({"type":200,"success":true,"data":{
            "cashierUrl":"https://cashier.cc-pay.cn.example.invalid/cashier?id=fixture"
        }}))
        .is_err()
    );
}

#[test]
fn payment_requires_matching_bill_transaction_amount_and_product() {
    let mut response = json!({"id":"bill","itemId":"other-id","transactionId":"transaction",
        "money":"0.10","fromType":"campus_card_fee","status":"2",
        "note":{"feeInfo":{"paymentItemId":"item"}}});
    assert_eq!(
        bill_outcome(&response, "bill", "item", "transaction", 10),
        Ok(BillOutcome::Syncing)
    );
    response["status"] = json!("1");
    assert_eq!(
        bill_outcome(&response, "bill", "item", "transaction", 10),
        Ok(BillOutcome::Paid)
    );
    assert!(bill_outcome(&response, "bill", "item", "another-order", 10).is_err());
    assert!(bill_outcome(&response, "bill", "item", "transaction", 100).is_err());
}

struct Store;
impl SessionStore for Store {
    fn load_versioned(&self) -> Result<VersionedSession> {
        Ok(VersionedSession {
            revision: 0,
            snapshot: None,
        })
    }
    fn compare_exchange(&self, _: u64, _: Option<&SessionSnapshot>) -> Result<SessionMutation> {
        panic!("校园卡业务 Cookie 不得写回学校会话")
    }
}

struct Step {
    host: &'static str,
    path: &'static str,
    response: Option<serde_json::Value>,
}

struct Transport(Arc<Mutex<VecDeque<Step>>>);

#[async_trait::async_trait]
impl HttpTransport for Transport {
    async fn execute(&self, request: HttpRequest) -> Result<HttpResponse> {
        let step = self.0.lock().unwrap().pop_front().expect("不应重放写请求");
        let url = url::Url::parse(&request.url).unwrap();
        assert_eq!(url.host_str(), Some(step.host));
        assert_eq!(url.path(), step.path);
        match step.path {
            "/api/payment" => {
                assert_eq!(request.method, HttpMethod::Post);
                let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
                let choice = if step.response.as_ref().is_some_and(|v| v["type"] == 200) {
                    "close-old"
                } else {
                    ""
                };
                assert_eq!(body["choice"], choice);
                assert_eq!(body["itemId"], "item");
                assert!(body["money"].is_number());
                assert_eq!(super::amount(&body["money"]), Some(10));
                let identity: serde_json::Value =
                    serde_json::from_str(body["feeInfo"].as_str().unwrap()).unwrap();
                assert_eq!(
                    identity,
                    json!({"stuNo":"fixture-account","realName":"Fixture"})
                );
            }
            "/transaction/pay" => {
                assert_eq!(request.method, HttpMethod::Get);
                assert_eq!(request.headers["version"], "v2");
                let query: std::collections::BTreeMap<_, _> = url.query_pairs().collect();
                assert_eq!(query["id"], "transaction");
                assert_eq!(query["payWayId"], "token-channel");
                assert_eq!(query["phoneNumber"], "");
                assert_eq!(query["ecCode"], "icbc");
            }
            "/api/campus_card/balance" => {
                assert_eq!(
                    url.query_pairs().find(|(k, _)| k == "stuNo").unwrap().1,
                    "fixture-account"
                );
            }
            "/login" if step.host == "sso.buaa.edu.cn" => {
                assert_eq!(
                    super::single_parameter(&url, "service").as_deref(),
                    Some(super::PASS)
                );
                let mut result = HttpResponse::new(302, &request.url, Vec::new());
                result.headers.insert(
                    "location".into(),
                    vec![step.response.unwrap().as_str().unwrap().to_owned()],
                );
                return Ok(result);
            }
            "/login" => {
                assert_eq!(
                    super::single_parameter(&url, "ticket").as_deref(),
                    Some("ST-fixture")
                );
                return Ok(HttpResponse::new(
                    200,
                    &request.url,
                    b"synthetic HTML shell".to_vec(),
                ));
            }
            _ => assert_eq!(request.method, HttpMethod::Get),
        }
        let body = step.response.ok_or_else(|| {
            UbaaError::new(
                ErrorCode::Timeout,
                ErrorKind::Network,
                true,
                "synthetic timeout",
            )
        })?;
        Ok(HttpResponse::new(
            200,
            &request.url,
            body.to_string().into_bytes(),
        ))
    }
}

fn mall(path: &'static str, response: Option<serde_json::Value>) -> Step {
    Step {
        host: "mall.cc-pay.cn",
        path,
        response,
    }
}
fn cashier(path: &'static str, response: Option<serde_json::Value>) -> Step {
    Step {
        host: "cashier.cc-pay.cn",
        path,
        response,
    }
}
macro_rules! success {
    ($data:expr) => {
        Some(json!({"type":200,"success":true,"data":$data}))
    };
}
fn setup(steps: Vec<Step>) -> (ClientRuntime, Arc<Mutex<VecDeque<Step>>>) {
    let queue = Arc::new(Mutex::new(steps.into()));
    let mut runtime =
        ClientRuntime::new(ConnectionMode::Direct, Transport(queue.clone()), Store).unwrap();
    runtime.remember_account_name(Some("fixture-account"));
    (runtime, queue)
}
fn preflight() -> Vec<Step> {
    vec![
        mall(
            "/api/bill/note/feeInfo",
            success!(json!({"stuNo":"fixture-account","realName":"Fixture"})),
        ),
        cashier(
            "/api/pay_ways",
            success!(json!({
                "normal":[{"name":"ecpay_token","id":"token-channel"}], "ecCode":["icbc"]
            })),
        ),
    ]
}

#[tokio::test]
async fn explicit_conflict_replaces_old_order_once_and_lost_payment_response_is_read_back() {
    let mut steps = preflight();
    steps.extend([
        mall("/api/payment", Some(json!({"type":406,"sub_type":4_060_003}))),
        mall("/api/payment", success!(json!({"cashierUrl":"https://cashier.cc-pay.cn/cashier?id=transaction"}))),
        cashier("/transaction", success!(json!({
            "id":"transaction","goodsId":"item","money":"0.1","currency":"CNY",
            "status":"wait_payer_pay","targetOrderId":"bill",
            "returnUrl":"https://mall.cc-pay.cn/transaction_result?billId=bill"
        }))),
        cashier("/transaction/pay", None),
        mall("/api/check_pay_result/by_sys", success!(json!({
            "id":"bill","transactionId":"transaction","money":"0.1","fromType":"campus_card_fee",
            "status":"1","note":{"feeInfo":{"paymentItemId":"item"}}
        }))),
    ]);
    let (mut runtime, remaining) = setup(steps);
    assert_eq!(
        super::recharge(&mut runtime, "item", 10, "icbc").await,
        Ok(BillOutcome::Paid)
    );
    assert!(remaining.lock().unwrap().is_empty());
}

#[tokio::test]
async fn lost_create_response_never_replaces_or_pays() {
    let mut steps = preflight();
    steps.push(mall("/api/payment", None));
    let (mut runtime, remaining) = setup(steps);
    assert_eq!(
        super::recharge(&mut runtime, "item", 10, "icbc")
            .await
            .unwrap_err()
            .code,
        ErrorCode::OutcomeUnknown
    );
    assert!(remaining.lock().unwrap().is_empty());
}

#[tokio::test]
async fn pass_reads_project_only_balance_and_active_wallet_codes() {
    let (mut runtime, remaining) = setup(vec![
        Step {
            host: "pass.cc-pay.cn",
            path: "/api/campus_card/balance",
            response: success!(json!({
                "balance":"28.06","unclaimedAmount":"3.1","status":"1"
            })),
        },
        Step {
            host: "pass.cc-pay.cn",
            path: "/api/bound_ec_tokens",
            response: success!(json!([
                {"nickName":"icbc","isDeleted":false,"id":"fixture-only"},
                {"nickName":"ccb","isDeleted":true},
                {"nickName":"icbc","isDeleted":false}
            ])),
        },
    ]);
    assert_eq!(super::balance(&mut runtime).await.unwrap(), 2806);
    assert_eq!(super::bound_wallets(&mut runtime).await.unwrap(), ["icbc"]);
    assert!(remaining.lock().unwrap().is_empty());
}

#[tokio::test]
async fn pass_login_shell_does_not_mask_an_unauthenticated_wallet_read() {
    let (mut runtime, remaining) = setup(vec![
        Step {
            host: "sso.buaa.edu.cn",
            path: "/login",
            response: Some(json!("https://pass.cc-pay.cn/login?ticket=ST-fixture")),
        },
        Step {
            host: "pass.cc-pay.cn",
            path: "/login",
            response: None,
        },
        Step {
            host: "pass.cc-pay.cn",
            path: "/api/bound_ec_tokens",
            response: Some(json!({"type":401,"success":false})),
        },
    ]);
    super::login(&mut runtime).await.unwrap();
    assert_eq!(
        super::bound_wallets(&mut runtime).await.unwrap_err().code,
        ErrorCode::AuthenticationRequired
    );
    assert!(remaining.lock().unwrap().is_empty());
}

#[tokio::test]
async fn service_ticket_is_never_forwarded_to_an_untrusted_host() {
    let (mut runtime, remaining) = setup(vec![Step {
        host: "sso.buaa.edu.cn",
        path: "/login",
        response: Some(json!(
            "https://pass.cc-pay.cn.example.invalid/login?ticket=ST-fixture"
        )),
    }]);
    assert_eq!(
        super::login(&mut runtime).await.unwrap_err().code,
        ErrorCode::UpstreamChanged
    );
    assert!(remaining.lock().unwrap().is_empty());
}
