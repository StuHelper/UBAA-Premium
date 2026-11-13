//! 校园卡充值的宿主合同。仅在 Direct 复用已有学校会话。
#![allow(clippy::missing_errors_doc)]

use crate::domain::ConnectionMode;
use crate::error::{Result, UbaaError};
use crate::features::campus_card::{self as wire, BillOutcome};
use crate::runtime::ClientRuntime;

use super::{UbaaClient, types::Operation};

#[derive(Clone, Copy)]
pub enum CampusCardPayment {
    Paid,
    Syncing,
}

impl UbaaClient {
    async fn campus_card_session(&mut self) -> Result<ClientRuntime> {
        self.resolve_operation(Operation::CampusCard)
            .map_err(|error| error.error)?;
        let parent = &self.direct_runtime;
        parent.ensure_primary_client()?;
        parent.ensure_session_revision()?;
        parent.check_authentication_scope()?;
        if !parent.has_local_session() || parent.account_name().is_none() {
            return Err(wire::auth_required());
        }
        let mut runtime = parent.fork_with_cookie_filter(|cookie| {
            matches!(
                cookie.domain.trim_start_matches('.'),
                "sso.buaa.edu.cn" | "buaa.edu.cn"
            )
        });
        wire::login(&mut runtime).await?;
        Ok(runtime)
    }

    pub async fn campus_card_wallets(&mut self) -> Result<Vec<String>> {
        self.network_control()
            .run_read(
                ConnectionMode::Direct,
                false,
                Box::pin(async {
                    let mut runtime = self.campus_card_session().await?;
                    wire::bound_wallets(&mut runtime).await
                }),
            )
            .await
    }

    pub async fn campus_card_balance(&mut self) -> Result<u32> {
        self.network_control()
            .run_read(
                ConnectionMode::Direct,
                false,
                Box::pin(async {
                    let mut runtime = self.campus_card_session().await?;
                    wire::balance(&mut runtime).await
                }),
            )
            .await
    }

    pub async fn campus_card_recharge(
        &mut self,
        cents: u32,
        wallet: &str,
    ) -> Result<CampusCardPayment> {
        if cents == 0
            || wallet.is_empty()
            || wallet.len() > 128
            || !wallet
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
        {
            return Err(UbaaError::invalid_input("充值金额或数币钱包无效"));
        }
        let mut runtime = self.campus_card_session().await?;
        let item = wire::item(&mut runtime).await?;
        match wire::recharge(&mut runtime, &item, cents, wallet).await? {
            BillOutcome::Paid => Ok(CampusCardPayment::Paid),
            BillOutcome::Syncing => Ok(CampusCardPayment::Syncing),
            BillOutcome::Pending | BillOutcome::Closed => {
                unreachable!("未支付订单不会作为成功返回")
            }
        }
    }
}
