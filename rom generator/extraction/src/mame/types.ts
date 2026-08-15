export type CPUType =
  | "sm5a"
  | "kb1013vk12"
  | "sm510"
  | "sm511"
  | "sm512"
  | "sm530"
  | "sm510_tiger"
  | "sm511_tiger1bit"
  | "sm511_tiger2bit";

export type Screen =
  | {
      type: "single";
      width: number;
      height: number;
    }
  | {
      type: "dualVertical";

      top: {
        width: number;
        height: number;
      };

      bottom: {
        width: number;
        height: number;
      };
    }
  | {
      type: "dualHorizontal";

      left: {
        width: number;
        height: number;
      };

      right: {
        width: number;
        height: number;
      };
    }
  | {
      type: "tripleHorizontal";

      left: {
        width: number;
        height: number;
      };

      middle: {
        width: number;
        height: number;
      };

      right: {
        width: number;
        height: number;
      };
    };

export interface PresetDefinition {
  cpu: CPUType;

  screen: Screen;
}

export interface PlatformSpecification {
  device: PresetDefinition;
  portMap: PlatformPortMapping;
  metadata: Metadata;
  rom: ROMName;
  /** MAME SYST parent, used for inherited artwork and screen assets. */
  parent?: string;
  /** Capability limitation discovered from the MAME driver. */
  unsupportedReason?: string;
  voice?: VoiceDefinition;
  auxRom?: AuxROMDefinition;
  /** Preferred folder below the artwork root, with standard ZIP fallback. */
  artworkSubdirectory?: string;
  /** Enable the package-declared SM530 startup-sound compatibility behavior. */
  defaultSoundOn?: boolean;
}

export type AuxROMDefinition = {
  type: "ha1152";
  region: "sfx";
  rom: string;
  size: number;
  romHash: string;
};

export interface VoiceDefinition {
  sampleSet: string;
  /** Sample command 1 is at index 0. Null entries are intentional holes. */
  commands: (string | null)[];
}

export interface ROMName {
  rom: string;
  melody: string | undefined;
  melodyHash?: string;
  romOwner?: string;
  romHash: string;
}

export interface Metadata {
  year: string;
  company: string;
  name: string;
}

/* Inputs */

export type Action =
  | "joyUp"
  | "joyDown"
  | "joyLeft"
  | "joyRight"
  | "leftJoyUp"
  | "leftJoyDown"
  | "leftJoyLeft"
  | "leftJoyRight"
  | "rightJoyUp"
  | "rightJoyDown"
  | "rightJoyLeft"
  | "rightJoyRight"
  | "button1"
  | "button2"
  | "button3"
  | "button4"
  | "button5"
  | "button6"
  | "button7"
  | "button8"
  | "select"
  | "start1"
  | "start2"
  | "service1"
  | "service2"
  | "service3"
  | "service4"
  | "volumeDown"
  | "powerOn"
  | "powerOff"
  // Analog controls are preserved so capability filtering can reject them.
  | "dial"
  // Keypad is not supported
  | "keypad"
  | "custom"
  | "customUpDown"
  | "customButtonHour"
  | "unused";

export interface NamedAction {
  action: Action;
  activeLow: boolean;
  name?: string;
  /** MAME PORT_PLAYER owner. Omitted for the primary/default player. */
  player?: number;
}

export type UndfAction = NamedAction | undefined;

export type Port =
  | {
      type: "s";
      /**
       * IN.#
       */
      index: number;

      bitmap: [UndfAction, UndfAction, UndfAction, UndfAction];
    }
  | {
      type: "acl" | "b" | "ba";

      bit: UndfAction;
    };

export interface PlatformPortMapping {
  ports: Port[];
  include?: string;
  groundLastIndex?: number;
}
