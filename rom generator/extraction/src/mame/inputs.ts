import {
  Action,
  NamedAction,
  PlatformPortMapping,
  Port,
  UndfAction,
} from "./types";

const PORT_START_REGEX = /^\s*PORT_START\("(.*)"\)/;

/** Captures bit, high/low active status, and input. */
const PORT_BIT_REGEX =
  /PORT_BIT\(\s*([0-9A-Fa-fxX]+)\s*,\s*(.*?)\s*,\s*(.*?)\s*\)/;

// Parse PORT_NAME separately. Making this an optional suffix of PORT_BIT lets
// the preceding wildcard consume it while the overall expression still
// succeeds, silently dropping every human-readable input name.
const PORT_NAME_REGEX = /PORT_NAME\(\s*(?:u8|u|U|L)?"([^"]*)"\s*\)/;

const PORT_PLAYER_REGEX = /PORT_PLAYER\(\s*([0-9]+)\s*\)/;

const PORT_CONFSETTING_REGEX = /PORT_CONFSETTING\(\s*([0-9A-Fa-fxX]+)\s*,/;

const PORT_INCLUDE_REGEX = /PORT_INCLUDE\(\s*(.*)\s*\)/;

const PORT_MODIFY_REGEX = /PORT_MODIFY\("(.*)"\)/;

type PortType =
  | {
      type: Exclude<Port["type"], "s">;
    }
  | {
      type: "s";
      index: number;
    };

export const parseInputs = (
  inputBody: string,
  deviceName: string
): PlatformPortMapping => {
  const lines = inputBody.trim().split("\n");

  let currentPort: Port | undefined = undefined;
  let ignoredPortBody = false;
  const ports: Port[] = [];

  // If set, this port includes port mapping from another console
  let portInclude: string | undefined = undefined;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let match = line.match(PORT_START_REGEX);

    if (!match) {
      match = line.match(PORT_MODIFY_REGEX);
    }
    // Either PORT_START or PORT_MODIFY
    if (match) {
      // Example: PORT_START("IN.0")
      const name = match[1];

      if (currentPort) {
        ports.push(currentPort);
      }

      // A new MAME port always ends the preceding physical port. Unsupported
      // pseudo-ports such as "FAKE" must not leave currentPort pointing at it,
      // or their following bits will overwrite and duplicate the prior port.
      currentPort = undefined;

      const portType = parsePortName(name, deviceName);
      ignoredPortBody = !portType;

      if (portType) {
        switch (portType.type) {
          case "s": {
            currentPort = {
              ...portType,
              bitmap: [undefined, undefined, undefined, undefined],
            };
            break;
          }
          default: {
            currentPort = {
              ...portType,
              bit: undefined,
            };
            break;
          }
        }
      }
    }

    match = line.match(PORT_BIT_REGEX);
    if (match) {
      const [_, unparsedBit, unparsedActive, unparsedButton] = match;
      const portName = line.match(PORT_NAME_REGEX)?.[1];
      const playerMatch = line.match(PORT_PLAYER_REGEX);
      const player = playerMatch
        ? Number.parseInt(playerMatch[1], 10)
        : undefined;

      const bit = parseInt(
        unparsedBit.startsWith("0x") ? unparsedBit.slice(2) : unparsedBit,
        16
      );

      const bitIndex = indexFromBit(bit);
      const button = parseButton(unparsedButton, line);

      if (!button) {
        console.log(
          `Unknown button action ${unparsedButton} for device ${deviceName}`
        );
        continue;
      }

      const activeHigh =
        unparsedActive === "IP_ACTIVE_HIGH" ||
        button.startsWith("custom") ||
        button === "dial";

      if (!currentPort) {
        if (ignoredPortBody) {
          continue;
        }
        console.log(
          `Attempted to add button ${line} without port to device ${deviceName}`
        );
        continue;
      }

      const namedAction: NamedAction = {
        action: button,
        activeLow: !activeHigh,
        name: portName,
        player,
      };

      if (currentPort.type === "s") {
        const targetPort = sPortForBit(currentPort, ports, bitIndex);
        targetPort.bitmap[bitIndex % 4] = namedAction;
      } else {
        // All other ports
        currentPort.bit = namedAction;
      }
    }

    match = line.match(PORT_CONFSETTING_REGEX);
    if (match) {
      // This is a cheat option. We want the default (the first option)
      const [_, unparsedBit] = match;

      const bit = parseInt(
        unparsedBit.startsWith("0x") ? unparsedBit.slice(2) : unparsedBit,
        16
      );

      const bitIndex = indexFromBit(bit);

      if (currentPort) {
        if (currentPort.type === "s") {
          const targetPort = sPortForBit(currentPort, ports, bitIndex);

          if (!targetPort.bitmap[bitIndex % 4]) {
            // No configured value for that port index. This is probably the first (default)
            const namedAction: NamedAction = {
              action: "unused",
              activeLow: false,
            };

            targetPort.bitmap[bitIndex % 4] = namedAction;
          }
        } else {
          // Single bit port
          if (!currentPort.bit) {
            // No configured value for that port. This is probably the first (default)
            const namedAction: NamedAction = {
              action: "unused",
              // If bit is 1, the default setting is on/high
              activeLow: bit === 1,
            };

            currentPort.bit = namedAction;
          }
        }
      }
    }

    match = line.match(PORT_INCLUDE_REGEX);
    if (match) {
      portInclude = match[1].trim();
    }
  }

  if (currentPort) {
    ports.push(currentPort);
  }

  const filteredSortedPorts = ports
    .filter((p) => {
      // Strip empty S inputs
      if (p.type === "s" && p.bitmap.filter((b) => !!b).length === 0) {
        return false;
      }

      return true;
    })
    .sort((a, b) => {
      const portIndex = (port: Port): number => {
        switch (port.type) {
          case "s":
            return port.index;
          // S takes 0-7, start at 8
          case "b":
            return 8;
          case "ba":
            return 9;
          case "acl":
            return 10;
        }
      };

      return portIndex(a) - portIndex(b);
    });

  return {
    ports: filteredSortedPorts,
    include: portInclude,
  };
};

export const collapseInputs = (ports: {
  [name: string]: PlatformPortMapping;
}): {
  [name: string]: PlatformPortMapping;
} => {
  const collapsedPorts: {
    [name: string]: PlatformPortMapping;
  } = {};

  for (const [deviceName, port] of Object.entries(ports)) {
    let outputPort: PlatformPortMapping;
    if (port.include) {
      const flatPortMap: {
        [id: string]: Port;
      } = {};

      for (const innerPort of port.ports) {
        const name = nameInnerPort(innerPort);

        flatPortMap[name] = innerPort;
      }

      const includedPort = ports[port.include];

      if (!includedPort) {
        console.log(
          `Could not find included port ${port.include} from device ${deviceName}`
        );
        continue;
      }

      if (includedPort.include) {
        console.log(
          `Included port ${port.include} from device ${deviceName} includes another port`
        );
      }

      for (const innerPort of includedPort.ports) {
        const name = nameInnerPort(innerPort);

        const existingPort = flatPortMap[name];
        if (existingPort) {
          // Both definitions have this port. We need to merge
          if (innerPort.type === "s" && existingPort.type === "s") {
            // Second check to satisfy TS
            for (let i = 0; i < 4; i++) {
              const newBit = innerPort.bitmap[i];
              const existingBit = existingPort.bitmap[i];

              if (existingBit) {
                existingPort.bitmap[i] = existingBit;
              } else {
                existingPort.bitmap[i] = newBit;
              }
            }
          } else {
            if (
              innerPort.type !== "s" &&
              existingPort.type !== "s" &&
              !existingPort.bit
            ) {
              existingPort.bit = innerPort.bit;
            }
          }
        } else {
          // Def only on parent, copy it over
          flatPortMap[name] = innerPort;
        }
      }

      outputPort = {
        ...port,
        ports: [...Object.values(flatPortMap)],
      };
    } else {
      outputPort = port;
    }

    const sortedPorts = outputPort.ports.sort((a, b) => {
      const portIndex = (port: Port): number => {
        switch (port.type) {
          case "s":
            return port.index;
          // S takes 0-7, start at 8
          case "b":
            return 8;
          case "ba":
            return 9;
          case "acl":
            return 10;
        }
      };

      return portIndex(a) - portIndex(b);
    });

    collapsedPorts[deviceName] = { ...outputPort, ports: sortedPorts };
  }

  return collapsedPorts;
};

const nameInnerPort = (port: Port): string => {
  if (port.type === "s") {
    return `s${port.index}`;
  }

  return port.type;
};

const sPortForBit = (
  currentPort: Extract<Port, { type: "s" }>,
  ports: Port[],
  bitIndex: number
): Extract<Port, { type: "s" }> => {
  const index = currentPort.index + Math.floor(bitIndex / 4);

  if (index === currentPort.index) {
    return currentPort;
  }

  const existing = ports.find(
    (port): port is Extract<Port, { type: "s" }> =>
      port.type === "s" && port.index === index
  );

  if (existing) {
    return existing;
  }

  const port: Extract<Port, { type: "s" }> = {
    type: "s",
    index,
    bitmap: [undefined, undefined, undefined, undefined],
  };

  ports.push(port);

  return port;
};

const parseButton = (button: string, line = ""): Action | undefined => {
  switch (button) {
    case "IPT_JOYSTICK_UP":
      return "joyUp";
    case "IPT_JOYSTICK_DOWN":
      return "joyDown";
    case "IPT_JOYSTICK_LEFT":
      return "joyLeft";
    case "IPT_JOYSTICK_RIGHT":
      return "joyRight";

    case "IPT_JOYSTICKLEFT_UP":
      return "leftJoyUp";
    case "IPT_JOYSTICKLEFT_DOWN":
      return "leftJoyDown";
    case "IPT_JOYSTICKLEFT_LEFT":
      return "leftJoyLeft";
    case "IPT_JOYSTICKLEFT_RIGHT":
      return "leftJoyRight";

    case "IPT_JOYSTICKRIGHT_UP":
      return "rightJoyUp";
    case "IPT_JOYSTICKRIGHT_DOWN":
      return "rightJoyDown";
    case "IPT_JOYSTICKRIGHT_LEFT":
      return "rightJoyLeft";
    case "IPT_JOYSTICKRIGHT_RIGHT":
      return "rightJoyRight";

    case "IPT_BUTTON1":
      return "button1";
    case "IPT_BUTTON2":
      return "button2";
    case "IPT_BUTTON3":
      return "button3";
    case "IPT_BUTTON4":
      return "button4";
    case "IPT_BUTTON5":
      return "button5";
    case "IPT_BUTTON6":
      return "button6";
    case "IPT_BUTTON7":
      return "button7";
    case "IPT_BUTTON8":
      return "button8";

    case "IPT_START":
    case "IPT_START1":
      return "start1";
    case "IPT_START2":
      return "start2";

    case "IPT_SELECT":
      return "select";

    case "IPT_SERVICE1":
      return "service1";
    case "IPT_SERVICE2":
      return "service2";
    case "IPT_SERVICE3":
      return "service3";
    case "IPT_SERVICE4":
      return "service4";

    case "IPT_VOLUME_DOWN":
      return "volumeDown";
    case "IPT_POWER_ON":
      return "powerOn";
    case "IPT_POWER_OFF":
      return "powerOff";

    case "IPT_DIAL":
      return "dial";

    // Keypad is not supported
    case "IPT_KEYPAD":
      return "keypad";

    case "IPT_CUSTOM":
      return parseCustomButton(line);

    case "IPT_UNUSED":
      return "unused";
  }

  return undefined;
};

const parseCustomButton = (line: string): Action => {
  const normalizedLine = line.toLowerCase();

  if (normalizedLine.includes("up/down")) {
    return "customUpDown";
  }

  if (normalizedLine.includes("button/hour")) {
    return "customButtonHour";
  }

  // Keypad and other game-specific custom inputs are intentionally left
  // generic until the core has a preservation-friendly mapping for them.
  return "custom";
};

const parsePortName = (
  name: string,
  deviceName: string
): PortType | undefined => {
  if (name.startsWith("IN.")) {
    // S input mapping
    return {
      type: "s",
      index: parseInt(name.slice(3)),
    };
  } else if (name === "ACL") {
    // ACL
    return { type: "acl" };
  } else if (name === "B") {
    // B input
    return { type: "b" };
  } else if (name === "BA") {
    // BA input
    return { type: "ba" };
  }
  if (name === "FAKE") {
    // Silently skip
  } else {
    console.log(`Unknown port ${name} for device ${deviceName}`);
  }

  return undefined;
};

const indexFromBit = (bit: number): number => {
  let value = bit;

  for (let count = 0; count < 8; count++) {
    if (value & 0x1) {
      return count;
    }

    value = value >> 1;
  }

  return 3;
};
