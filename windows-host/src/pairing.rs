use std::{collections::HashMap, path::Path};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::fs;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairedDevice {
    pub device_id: Uuid,
    pub device_name: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PairingStore {
    pub devices: HashMap<Uuid, PairedDevice>,
}

impl PairingStore {
    pub async fn load_or_default(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if !path.exists() {
            return Ok(Self::default());
        }

        let raw = fs::read_to_string(path).await?;
        Ok(serde_json::from_str(&raw)?)
    }

    pub async fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        let body = serde_json::to_string_pretty(self)?;
        fs::write(path, body).await?;
        Ok(())
    }

    pub fn is_paired(&self, device_id: &Uuid) -> bool {
        self.devices.contains_key(device_id)
    }

    pub fn add(&mut self, device: PairedDevice) {
        self.devices.insert(device.device_id, device);
    }
}
