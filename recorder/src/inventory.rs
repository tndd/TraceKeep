//! Preserve the existing inventory projections, including the incident snapshot.
use crate::metrics::{query, Evidence, Query};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

query!(Board, "Win32_BaseBoard", { Manufacturer:String, Product:String, Version:String });
query!(Bios, "Win32_BIOS", { Manufacturer:String, SMBIOSBIOSVersion:String, ReleaseDate:String });
query!(Cpu, "Win32_Processor", { Name:String, NumberOfCores:u32, NumberOfLogicalProcessors:u32, MaxClockSpeed:u32, CurrentClockSpeed:u32 });
query!(Memory, "Win32_PhysicalMemory", { BankLabel:String, DeviceLocator:String, Manufacturer:String, PartNumber:String, Capacity:u64, Speed:u32, ConfiguredClockSpeed:u32, ConfiguredVoltage:u32, MinVoltage:u32, MaxVoltage:u32 });
query!(Drivers, "Win32_PnPSignedDriver", { DeviceName:String, DeviceClass:String, DeviceID:String, DriverVersion:String, DriverDate:String, DriverProviderName:String, InfName:String, IsSigned:bool });
query!(Devices, "Win32_PnPEntity", { Name:String, PNPClass:String, DeviceID:String, Service:String, Status:String, ConfigManagerErrorCode:u32 });
query!(Disks, "Win32_DiskDrive", { Index:u32, Model:String, FirmwareRevision:String, InterfaceType:String, Size:u64, Status:String });
query!(Os, "Win32_OperatingSystem", { Version:String, BuildNumber:String, LastBootUpTime:String, InstallDate:String, OSArchitecture:String });
query!(Updates, "Win32_QuickFixEngineering", { HotFixID:String, InstalledOn:String, Description:String });

// The old snapshot selects the same fields from six different classes. Some
// fields do not exist on a particular class: retain explicit nulls. Deserialize
// only this allowlist from SELECT *, never serialize provider objects/identities.
macro_rules! machine {
    ($name:ident, $class:literal) => {
        #[allow(non_snake_case)]
        #[derive(serde::Deserialize, serde::Serialize)]
        struct $name {
            Manufacturer: Option<String>,
            Name: Option<String>,
            Product: Option<String>,
            Version: Option<String>,
            SMBIOSBIOSVersion: Option<String>,
            ReleaseDate: Option<String>,
            DriverVersion: Option<String>,
            DriverDate: Option<String>,
            Model: Option<String>,
            FirmwareRevision: Option<String>,
            Capacity: Option<u64>,
            ConfiguredClockSpeed: Option<u32>,
            PartNumber: Option<String>,
        }
        impl crate::metrics::Query for $name {
            const CLASS: &'static str = $class;
            const FIELDS: &'static [&'static str] = &["*"];
        }
    };
}
machine!(MachineBoard, "Win32_BaseBoard");
machine!(MachineBios, "Win32_BIOS");
machine!(MachineCpu, "Win32_Processor");
machine!(MachineMemory, "Win32_PhysicalMemory");
machine!(MachineVideo, "Win32_VideoController");
machine!(MachineDisk, "Win32_DiskDrive");

#[cfg(windows)]
impl crate::metrics::Reader {
    pub fn inventory(&mut self) -> Value {
        let mut result = Evidence::default();
        macro_rules! add {
            ($key:literal,$kind:ty) => {
                result.add($key, $key, self.read::<$kind>(None, true, 512 * 1024));
            };
        }
        add!("board", Board);
        add!("bios", Bios);
        add!("cpu", Cpu);
        add!("memory", Memory);
        add!("drivers", Drivers);
        add!("devices", Devices);
        add!("disks", Disks);
        add!("os", Os);
        add!("updates", Updates);
        result.finish()
    }
    pub fn machine(&mut self) -> Value {
        let mut value = json!({"time":crate::now(),"errors":[]});
        macro_rules! add {($key:literal,$kind:ty) => {
            match self.read::<$kind>(None,true,512*1024) {
                Ok(rows)=>value[$key]=json!(rows),
                Err(error)=>value["errors"].as_array_mut().unwrap().push(json!({"category":$key,"error":error})),
            }
        }}
        add!("board", MachineBoard);
        add!("bios", MachineBios);
        add!("cpu", MachineCpu);
        add!("memory", MachineMemory);
        add!("video", MachineVideo);
        add!("disk", MachineDisk);
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn snapshot_drops_identity_and_metadata_but_retains_null_fields() {
        let row: MachineCpu =
            serde_json::from_value(json!({"Name":"synthetic","SerialNumber":"private",
            "PSComputerName":"private","CimClass":{"large":"metadata"},"PartNumber":null}))
            .unwrap();
        let row = serde_json::to_value(row).unwrap();
        assert_eq!(row.as_object().unwrap().len(), 13);
        assert_eq!(row["Name"], "synthetic");
        assert!(row["Product"].is_null());
        assert!(row.get("SerialNumber").is_none());
        assert!(row.get("CimClass").is_none());
    }
}
