//! 校园卡充值的宿主投影。
#![allow(clippy::missing_errors_doc)]

use crate::api::client::{
    BridgeClient, BridgeConnectionMode, BridgeError, catch_panic, disposed_error,
};
use ubaa_core::facade::campus_card::CampusCardPayment;

pub enum BridgeCampusCardPayment {
    Paid,
    Syncing,
}

impl BridgeClient {
    pub async fn campus_card_balance(&self) -> Result<u32, BridgeError> {
        catch_panic(async {
            self.inner
                .lock()
                .await
                .as_mut()
                .ok_or_else(disposed_error)?
                .campus_card_balance()
                .await
                .map_err(|error| BridgeError::from_core(error, Some(BridgeConnectionMode::Direct)))
        })
        .await
    }
    pub async fn campus_card_wallets(&self) -> Result<Vec<String>, BridgeError> {
        catch_panic(async {
            self.inner
                .lock()
                .await
                .as_mut()
                .ok_or_else(disposed_error)?
                .campus_card_wallets()
                .await
                .map_err(|error| BridgeError::from_core(error, Some(BridgeConnectionMode::Direct)))
        })
        .await
    }

    pub async fn campus_card_recharge(
        &self,
        cents: u32,
        wallet: String,
    ) -> Result<BridgeCampusCardPayment, BridgeError> {
        catch_panic(async {
            self.ensure_recovery_allowed().await?;
            let outcome = self
                .inner
                .lock()
                .await
                .as_mut()
                .ok_or_else(disposed_error)?
                .campus_card_recharge(cents, &wallet)
                .await
                .map_err(|error| {
                    BridgeError::from_core(error, Some(BridgeConnectionMode::Direct))
                })?;
            Ok(match outcome {
                CampusCardPayment::Paid => BridgeCampusCardPayment::Paid,
                CampusCardPayment::Syncing => BridgeCampusCardPayment::Syncing,
            })
        })
        .await
    }
}
