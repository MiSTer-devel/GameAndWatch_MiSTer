import { AuxROMDefinition } from "./types";

const ROM_REGION_REGEX_BUILDER = (name: string) =>
  new RegExp(`ROM_START\\(\\s*${name}\\s*\\)([\\s\\S]*?)ROM_END`);

const ROM_REGION_REGEX =
  /ROM_REGION\(\s*([^,]+),\s*"([^"]+)"[^)]*\)([\s\S]*?)(?=ROM_REGION\(|$)/gi;

const ROM_LOAD_REGEX =
  /ROM_LOAD\(\s*"([^"]+)"\s*,\s*([^,]+),\s*([^,]+),([^\r\n]*)/gi;

const SHA1_REGEX = /SHA1\(\s*([0-9a-f]{40})\s*\)/i;

const SCREEN_REGIONS = new Set([
  "screen",
  "screen_top",
  "screen_bottom",
  "screen_left",
  "screen_middle",
  "screen_right",
]);

type ROMSha = {
  name: string;
  sha: string;
};

const parseInteger = (value: string, context: string): number => {
  const trimmed = value.trim();
  if (!/^(?:0x[0-9a-f]+|[0-9]+)$/i.test(trimmed)) {
    throw new Error(`Unsupported integer ${trimmed} in ${context}`);
  }
  return Number.parseInt(
    trimmed,
    trimmed.toLowerCase().startsWith("0x") ? 16 : 10
  );
};

const parseSingleLoad = (
  regionBody: string,
  region: string,
  deviceName: string
): {
  name: string;
  offset: number;
  size: number;
  sha?: string;
  noDump: boolean;
} => {
  const matches = [...regionBody.matchAll(ROM_LOAD_REGEX)];
  if (matches.length !== 1) {
    throw new Error(
      `ROM region ${region} for ${deviceName} has ${matches.length} ROM_LOAD entries; expected 1`
    );
  }

  const [, name, rawOffset, rawSize, attributes] = matches[0];
  return {
    name,
    offset: parseInteger(rawOffset, `${deviceName}:${region} ROM offset`),
    size: parseInteger(rawSize, `${deviceName}:${region} ROM size`),
    sha: attributes.match(SHA1_REGEX)?.[1].toLowerCase(),
    noDump: /\bNO_DUMP\b/.test(attributes),
  };
};

export const parseRom = (
  content: string,
  deviceName: string
):
  | {
      rom: ROMSha;
      melody: ROMSha | undefined;
      auxRom: AuxROMDefinition | undefined;
    }
  | undefined => {
  const regex = ROM_REGION_REGEX_BUILDER(deviceName);

  const match = content.match(regex);

  if (!match) {
    console.log(`Could not find ROM block for device ${deviceName}`);
    return;
  }

  const body = match[1];

  let melody: ROMSha | undefined = undefined;
  let rom: ROMSha | undefined = undefined;
  let auxRom: AuxROMDefinition | undefined = undefined;

  for (const regionMatch of body.matchAll(ROM_REGION_REGEX)) {
    const declaredSize = parseInteger(
      regionMatch[1],
      `${deviceName}:${regionMatch[2]} region size`
    );
    const region = regionMatch[2];
    const regionBody = regionMatch[3];

    if (SCREEN_REGIONS.has(region)) {
      // Artwork SVGs are consumed by the renderer, not packaged as ROM data.
      continue;
    }

    const load = parseSingleLoad(regionBody, region, deviceName);

    if (region === "maincpu:melody") {
      if (!!melody) {
        throw new Error(`Melody ROM name is already set for ${deviceName}`);
      }
      if (!load.sha || load.noDump) {
        throw new Error(`Melody ROM for ${deviceName} has no dumped SHA1`);
      }
      melody = {
        name: load.name,
        sha: load.sha,
      };
    } else if (region === "maincpu") {
      if (!!rom) {
        throw new Error(`ROM name is already set for ${deviceName}`);
      }
      if (!load.sha || load.noDump) {
        throw new Error(`Program ROM for ${deviceName} has no dumped SHA1`);
      }
      rom = { name: load.name, sha: load.sha };
    } else if (region === "sfx") {
      if (auxRom) {
        throw new Error(`Auxiliary ROM is already set for ${deviceName}`);
      }
      if (
        declaredSize !== 0x80 ||
        load.offset !== 0 ||
        load.size !== 0x80 ||
        !load.sha ||
        load.noDump
      ) {
        throw new Error(
          `HA1152 sfx ROM for ${deviceName} must be a dumped 0x80-byte load at offset 0`
        );
      }
      auxRom = {
        type: "ha1152",
        region: "sfx",
        rom: load.name,
        size: load.size,
        romHash: load.sha,
      };
    } else if (
      region === "adpcm" &&
      declaredSize === 0x8000 &&
      load.name === "msm6373" &&
      load.offset === 0 &&
      load.size === 0x8000 &&
      load.noDump &&
      !load.sha
    ) {
      // The three MSM6373 regions are explicitly undumped. Their observable
      // behavior comes from the separately described MAME sample set.
      continue;
    } else {
      throw new Error(
        `Unsupported non-screen ROM region ${region} for ${deviceName}`
      );
    }
  }

  if (!rom) {
    console.log(`Could not find ROM name for device ${deviceName}`);
    return;
  }

  return {
    rom,
    melody,
    auxRom,
  };
};
