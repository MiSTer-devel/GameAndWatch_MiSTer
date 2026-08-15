import { readFileSync, writeFileSync } from "fs";
import { argv } from "process";
import { collapseInputs, parseInputs } from "./mame/inputs";
import { createPreset } from "./mame/presets";
import { parseRom } from "./mame/roms";
import {
  Metadata,
  PlatformPortMapping,
  PlatformSpecification,
  PresetDefinition,
  VoiceDefinition,
} from "./mame/types";

const PORT_SETTINGS_REGEX =
  /INPUT_PORTS_START\(\s+(.*)\s+\)([\s\S]*?)INPUT_PORTS_END/;

const CLASS_DEF_REGEX = /class\s+(.*_state)\s+:[\s\S]*?};/g;

const CLASS_DEF_CONSTUCTOR_REGEX = /void\s+(.*)\(machine_config\s*&\s*.*?\)/g;

// The system table, rather than machine-config constructors, is MAME's final
// list of runnable systems. The machine and input fields may deliberately name
// definitions belonging to a parent or sibling title.
const SYSTEM_DEF_REGEX =
  /(?:SYST|CONS)\(\s*([0-9?]{4})\s*,\s*([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)\s*,\s*[^,]*,\s*([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_:]+)\s*,\s*[^,]*,\s*"([^"]*)"\s*,\s*"([^"]*)"/g;

const SAMPLE_NAMES_REGEX =
  /static\s+const\s+char\s+\*const\s+([a-zA-Z0-9_]+)_sample_names\[\]\s*=\s*\{([\s\S]*?)\};/g;

const SAMPLE_NAME_TOKEN_REGEX = /"([^"]*)"|nullptr/g;

// Used to check if `inp_fixed_last` is called.
const PUBLIC_CONSTRUCTOR_REGEX_BUILDER = (deviceName: string) =>
  new RegExp(`${deviceName}\\(.*?\\)\\s*:[\\s\\S]*?{([^}]*)}`);

const INSTANCE_CONSTRUCTOR_REGEX_BUILDER = (
  stateName: string,
  deviceName: string
) =>
  new RegExp(
    `void\\s+${stateName}::${deviceName}\\(\\s*machine_config\\s+&\\s*config\\s*\\)\\s*{\\s*([\\s\\S]*?)\\s+}`
  );

const ROM_BLOCK_REGEX_BUILDER = (deviceName: string) =>
  new RegExp(
    `ROM_START\\(\\s*${deviceName}\\s*\\)([\\s\\S]*?)ROM_END`
  );

interface SystemDefinition {
  name: string;
  parent?: string;
  machine: string;
  input: string;
  stateClass: string;
  metadata: Metadata;
}

const homebrewTitles = {
  hbw_bride: { game: "gnw_dkjr", name: "Bride", year: "2018" },
  hbw_squeeze: { game: "gnw_mickdon", name: "Squeeze", year: "2018" },
};

// Title-specific artwork sources which are complete and better aligned than
// the default MAME artwork ZIP. Keep this in the extractor so regenerating
// the ignored manifest.json retains the selection.
const artworkSubdirectories: Record<string, string> = {
  nupogodi: "alternates/hydef",
};

// The Nelsonic SMB3 firmware uses its alarm-enable RAM bit as the game-melody
// gate and boots with that bit clear. Mark only this exact title for the
// optional core-side startup-sound compatibility behavior.
const defaultSoundOnTitles = new Set(["nsmb3"]);

const parseSystems = (file: string): SystemDefinition[] => {
  const systems: SystemDefinition[] = [];

  for (const match of file.matchAll(SYSTEM_DEF_REGEX)) {
    const [
      ,
      year,
      name,
      rawParent,
      machine,
      input,
      stateClass,
      company,
      fullName,
    ] = match;

    systems.push({
      name,
      parent: rawParent === "0" ? undefined : rawParent,
      machine,
      input,
      stateClass,
      metadata: {
        year,
        company,
        name: fullName,
      },
    });
  }

  return systems;
};

const parseVoiceDefinitions = (file: string): {
  [name: string]: VoiceDefinition;
} => {
  const definitions: { [name: string]: VoiceDefinition } = {};

  for (const match of file.matchAll(SAMPLE_NAMES_REGEX)) {
    const [, name, body] = match;
    const tokens = [...body.matchAll(SAMPLE_NAME_TOKEN_REGEX)].map(
      (token) => token[1] ?? null
    );

    if (tokens.length < 2 || tokens[tokens.length - 1] !== null) {
      console.log(`Malformed sample-name table ${name}_sample_names`);
      continue;
    }

    const rawSampleSet = tokens.shift();
    tokens.pop(); // trailing nullptr

    if (typeof rawSampleSet !== "string" || !rawSampleSet.startsWith("*")) {
      console.log(`Sample-name table ${name}_sample_names has no leading set`);
      continue;
    }

    definitions[name] = {
      sampleSet: rawSampleSet.slice(1),
      commands: tokens.map((sampleName) =>
        sampleName === null || sampleName.toLowerCase().startsWith("none")
          ? null
          : sampleName
      ),
    };
  }

  return definitions;
};

const romUsesUndumpedAdpcm = (file: string, deviceName: string): boolean => {
  const match = file.match(ROM_BLOCK_REGEX_BUILDER(deviceName));
  if (!match) {
    return false;
  }

  const body = match[1];
  return (
    /ROM_REGION\(\s*0x8000\s*,\s*"adpcm"/.test(body) &&
    /ROM_LOAD\([^\n]*NO_DUMP/.test(body)
  );
};

const assertUniquePhysicalPorts = (
  consoles: { [name: string]: PlatformSpecification }
): void => {
  for (const [name, console] of Object.entries(consoles)) {
    const identities = new Set<string>();

    for (const port of console.portMap.ports) {
      const identity = port.type === "s" ? `s${port.index}` : port.type;
      if (identities.has(identity)) {
        throw new Error(
          `System ${name} contains duplicate physical port ${identity}`
        );
      }
      identities.add(identity);
    }
  }
};

// This tool is constructed out of ad-hoc regex instead of being a clear
// "select block of a single platform and parse" because the MAME code isn't
// laid out in a way that makes that practical.
const run = () => {
  const mameSourcePath = argv[2];
  const manifestOutputPath = argv[3] ?? "manifest.json";
  const file = readFileSync(mameSourcePath, "utf8");
  const systems = parseSystems(file);
  const voiceDefinitions = parseVoiceDefinitions(file);

  // Get all port bodies.
  let ports: {
    [name: string]: PlatformPortMapping;
  } = {};
  const globalNames = new RegExp(PORT_SETTINGS_REGEX, "g");
  for (const match of file.matchAll(globalNames)) {
    const [, name, body] = match;

    if (name in ports) {
      console.log(`Duplicate input definition for ${name}`);
      return;
    }

    ports[name] = parseInputs(body, name);
  }

  ports = collapseInputs(ports);

  // Add grounded ports.
  for (const deviceName of Object.keys(ports)) {
    const portMap = ports[deviceName];
    const constructorMatch = file.match(
      PUBLIC_CONSTRUCTOR_REGEX_BUILDER(`${deviceName}_state`)
    );

    if (!constructorMatch || constructorMatch[1].trim() !== "inp_fixed_last();") {
      continue;
    }

    // Last named S port is grounded. Store the actual S index, which can
    // differ from the array position when MAME skips an input row.
    for (let i = portMap.ports.length - 1; i >= 0; i--) {
      const port = portMap.ports[i];
      if (port.type === "s") {
        portMap.groundLastIndex = port.index;
        break;
      }
    }
  }

  const machinePresets: { [name: string]: PresetDefinition } = {};
  const stateUnsupportedReasons: { [name: string]: string } = {};

  // Machine constructors define CPU and screen topology. They are definitions,
  // not the final title list: clones can use another machine constructor while
  // supplying their own ROM set and metadata in SYST.
  for (const match of file.matchAll(CLASS_DEF_REGEX)) {
    const [classDef, className] = match;
    const subdevices: string[] = [];

    if (/output_finder\s*</.test(classDef)) {
      stateUnsupportedReasons[className] =
        "uses non-LCD output_finder display outputs";
    }

    for (const constructorMatch of classDef.matchAll(
      CLASS_DEF_CONSTUCTOR_REGEX
    )) {
      subdevices.push(constructorMatch[1]);
    }

    const stateName = className.endsWith("_state")
      ? className.slice(0, -6)
      : className;

    subdevices.sort((a, b) => {
      if (a === stateName) return -1;
      if (b === stateName) return 1;
      return a.localeCompare(b);
    });

    for (const device of subdevices) {
      const constructorRegex = INSTANCE_CONSTRUCTOR_REGEX_BUILDER(
        className,
        device
      );
      const constructorMatch = file.match(constructorRegex);

      if (!constructorMatch) {
        // Some state classes declare helper configs that are not defined in
        // this driver. A SYST entry that actually selects one will still fail
        // below when its machine preset cannot be resolved.
        continue;
      }

      const preset = createPreset(constructorMatch[1], device);
      if (!preset) {
        console.log(`Could not find preset for device ${device}`);
        continue;
      }

      machinePresets[device] = preset;
    }
  }

  const consoles: { [name: string]: PlatformSpecification } = {};

  for (const system of systems) {
    const preset = machinePresets[system.machine];
    if (!preset) {
      console.log(
        `Could not find machine preset ${system.machine} for system ${system.name}`
      );
      continue;
    }

    const rom = parseRom(file, system.name);
    if (!rom) {
      continue;
    }

    const portMap = ports[system.input];
    if (!portMap) {
      console.log(
        `Could not find input definition ${system.input} for system ${system.name}`
      );
    }

    const voice = voiceDefinitions[system.name];
    const hasVoice = voice && romUsesUndumpedAdpcm(file, system.name);

    consoles[system.name] = {
      device: structuredClone(preset),
      portMap: portMap ? structuredClone(portMap) : { ports: [] },
      metadata: system.metadata,
      rom: {
        rom: rom.rom.name,
        melody: rom.melody?.name,
        melodyHash: rom.melody?.sha,
        romHash: rom.rom.sha,
        // Keep this compatibility field while parent becomes the canonical
        // source for inherited artwork and ROM assets.
        romOwner: system.parent,
      },
      parent: system.parent,
      unsupportedReason: stateUnsupportedReasons[system.stateClass],
      voice: hasVoice ? voice : undefined,
      auxRom: rom.auxRom,
      artworkSubdirectory: artworkSubdirectories[system.name],
      defaultSoundOn: defaultSoundOnTitles.has(system.name) || undefined,
    };
  }

  // Homebrew pass.
  for (const [homebrewTitle, { game: mameTitle, name, year }] of Object.entries(
    homebrewTitles
  )) {
    const existingConfig = consoles[mameTitle];

    if (!existingConfig) {
      console.log(
        `Could not find title entry "${mameTitle}" for homebrew ${homebrewTitle}`
      );
      continue;
    }

    const homebrewConfig = structuredClone(existingConfig);
    homebrewConfig.parent = mameTitle;
    homebrewConfig.rom.romOwner = mameTitle;
    homebrewConfig.portMap.include =
      homebrewConfig.portMap.include ?? mameTitle;
    homebrewConfig.metadata = {
      year,
      company: "Homebrew",
      name,
    };
    homebrewConfig.voice = undefined;
    homebrewConfig.auxRom = undefined;

    consoles[homebrewTitle] = homebrewConfig;
  }

  assertUniquePhysicalPorts(consoles);

  const orderedConsoles = Object.keys(consoles)
    .sort()
    .reduce((obj, key) => {
      obj[key] = consoles[key];
      return obj;
    }, {} as { [name: string]: PlatformSpecification });

  writeFileSync(
    manifestOutputPath,
    JSON.stringify(orderedConsoles, undefined, 4)
  );

  console.log(
    `Wrote ${manifestOutputPath} (${systems.length} MAME systems, ${Object.keys(
      orderedConsoles
    ).length} total entries)`
  );
};

if (argv.length < 3 || argv.length > 4) {
  console.log(`Received ${argv.length - 2} arguments. Expected 1 or 2\n`);
  console.log(
    "Usage: node extract.js [hh_sm510.cpp path] [manifest output path]"
  );

  process.exit(1);
}

run();
