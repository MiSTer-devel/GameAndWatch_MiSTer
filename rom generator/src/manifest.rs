use clap::ValueEnum;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformSpecification {
    pub device: PresetDefinition,
    pub port_map: PlatformPortMapping,
    pub metadata: Metdata,
    pub rom: ROMName,
    pub parent: Option<String>,
    pub unsupported_reason: Option<String>,
    pub voice: Option<VoiceDefinition>,
    pub aux_rom: Option<AuxROMDefinition>,
    /// Optional preferred subdirectory under the artwork root. If the
    /// alternate is absent, generation falls back to the standard title ZIP.
    pub artwork_subdirectory: Option<String>,
    /// Request the SM530 startup-sound compatibility behavior for titles
    /// whose firmware otherwise boots with melody disabled.
    pub default_sound_on: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceDefinition {
    pub sample_set: String,
    pub commands: Vec<Option<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuxROMDefinition {
    #[serde(rename = "type")]
    pub rom_type: AuxROMType,
    pub region: AuxROMRegion,
    pub rom: String,
    pub size: usize,
    pub rom_hash: String,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
pub enum AuxROMType {
    #[serde(rename = "ha1152")]
    HA1152,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum AuxROMRegion {
    Sfx,
}

/* ROM */

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ROMName {
    pub rom: String,
    pub melody: Option<String>,
    pub melody_hash: Option<String>,
    pub rom_owner: Option<String>,
    pub rom_hash: String,
}

/* Metdata */

#[derive(Debug, Deserialize)]
pub struct Metdata {
    // This is a year, as MAME has question marks in some years
    pub year: String,
    pub name: String,
    pub company: String,
}

/* Preset Definition */

#[derive(Debug, Deserialize)]
pub struct PresetDefinition {
    pub cpu: CPUType,
    pub screen: Screen,
}

#[derive(PartialEq, Clone, Debug, Deserialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum CPUType {
    SM5a,
    KB1013VK12,
    SM510,
    SM511,
    SM512,
    SM530,
    #[serde(rename = "sm510_tiger")]
    SM510Tiger,
    #[serde(rename = "sm511_tiger1bit")]
    SM511Tiger1Bit,
    #[serde(rename = "sm511_tiger2bit")]
    SM511Tiger2Bit,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
#[serde(tag = "type")]
pub enum Screen {
    Single {
        width: f32,
        height: f32,
    },
    DualVertical {
        top: Size,
        bottom: Size,
    },
    DualHorizontal {
        left: Size,
        right: Size,
    },
    TripleHorizontal {
        left: Size,
        middle: Size,
        right: Size,
    },
}

#[derive(PartialEq, Debug, Deserialize)]
pub struct Size {
    pub width: f32,
    pub height: f32,
}

/* Input Mapping */

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformPortMapping {
    pub ports: Vec<Port>,
    pub include: Option<String>,
    pub ground_last_index: Option<u8>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
#[serde(tag = "type")]
pub enum Port {
    S {
        index: usize,
        bitmap: [Option<NamedAction>; 4],
    },
    ACL {
        bit: Option<NamedAction>,
    },
    B {
        bit: Option<NamedAction>,
    },
    BA {
        bit: Option<NamedAction>,
    },
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NamedAction {
    pub action: Action,
    pub active_low: bool,
    pub name: Option<String>,
    pub player: Option<u8>,
}

#[derive(PartialEq, Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    JoyUp,
    JoyDown,
    JoyLeft,
    JoyRight,
    LeftJoyUp,
    LeftJoyDown,
    LeftJoyLeft,
    LeftJoyRight,
    RightJoyUp,
    RightJoyDown,
    RightJoyLeft,
    RightJoyRight,
    Button1,
    Button2,
    Button3,
    Button4,
    Button5,
    Button6,
    Button7,
    Button8,
    Select,
    Start1,
    Start2,
    Service1,
    Service2,
    VolumeDown,
    PowerOn,
    PowerOff,
    Keypad,
    Custom,
    CustomUpDown,
    CustomButtonHour,
    Dial,
    Service3,
    Service4,
    Unused,
}
