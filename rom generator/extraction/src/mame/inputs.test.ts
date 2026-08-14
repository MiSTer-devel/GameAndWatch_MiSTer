import assert from "assert";
import { collapseInputs, parseInputs } from "./inputs";

const shared = parseInputs(
  `
  PORT_START("IN.0")
  PORT_BIT( 0x04, IP_ACTIVE_HIGH, IPT_BUTTON1 ) PORT_PLAYER(2)

  PORT_START("IN.1")
  PORT_BIT( 0x01, IP_ACTIVE_HIGH, IPT_BUTTON1 )

  PORT_START("IN.2")
  PORT_BIT( 0x04, IP_ACTIVE_HIGH, IPT_JOYSTICK_DOWN ) PORT_PLAYER(2)
  PORT_BIT( 0x08, IP_ACTIVE_HIGH, IPT_JOYSTICK_UP ) PORT_PLAYER(2)

  PORT_START("IN.3")
  PORT_BIT( 0x01, IP_ACTIVE_HIGH, IPT_JOYSTICK_DOWN )
  PORT_BIT( 0x02, IP_ACTIVE_HIGH, IPT_JOYSTICK_UP )

  PORT_START("IN.4")
  PORT_BIT( 0x04, IP_ACTIVE_HIGH, IPT_JOYSTICK_RIGHT ) PORT_PLAYER(2)
  PORT_BIT( 0x08, IP_ACTIVE_HIGH, IPT_JOYSTICK_LEFT ) PORT_PLAYER(2)
  `,
  "microvs_shared"
);
const child = parseInputs(
  `
  PORT_INCLUDE( microvs_shared )
  PORT_START("B")
  PORT_CONFSETTING( 0x01, DEF_STR( Off ) )
  `,
  "gnw_boxing"
);
const collapsed = collapseInputs({ microvs_shared: shared, gnw_boxing: child });

const playerTwoCells = collapsed.gnw_boxing.ports.flatMap((port) => {
  if (port.type !== "s") {
    return port.bit?.player === 2 ? [port.type] : [];
  }

  return port.bitmap.flatMap((action, bit) =>
    action?.player === 2 ? [`s${port.index}.${bit}`] : []
  );
});

assert.deepStrictEqual(playerTwoCells, ["s0.2", "s2.2", "s2.3", "s4.2", "s4.3"]);
const primaryPort = collapsed.gnw_boxing.ports.find(
  (port) => port.type === "s" && port.index === 1
);
assert(primaryPort?.type === "s");
assert.strictEqual(primaryPort.bitmap[0]?.player, undefined);

console.log("Input parser player-ownership tests passed");
