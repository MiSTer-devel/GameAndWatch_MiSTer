import assert from "assert";
import { parseRom } from "./roms";

const source = `
ROM_START( nstarfox )
    ROM_REGION( 0x800, "maincpu", 0 )
    ROM_LOAD( "643.program", 0x000, 0x800, CRC(ac1f5c68) SHA1(165cefeba9abc8725e55d15fdc218b07857d4cfe) )
    ROM_REGION( 0x100, "maincpu:melody", 0 )
    ROM_LOAD( "643.melody", 0x000, 0x100, CRC(6684f6b7) SHA1(32056467f796cb2e3c9f05c364419e7935fd1361) )
    ROM_REGION( 0x80, "sfx", 0 )
    ROM_LOAD( "ha1152_001a", 0x00, 0x80, CRC(fba00b7c) SHA1(5dfb15eee3c57bbca80f485f68442e5f7c6bc5e4) )
    ROM_REGION( 155284, "screen", 0 )
    ROM_LOAD( "nstarfox.svg", 0, 155284, CRC(843c0fa2) SHA1(bed08fcc8e9fd20624052d91db90923897a1cf7c) )
ROM_END
`;

const starFox = parseRom(source, "nstarfox");
assert(starFox);
assert.deepStrictEqual(starFox.auxRom, {
  type: "ha1152",
  region: "sfx",
  rom: "ha1152_001a",
  size: 0x80,
  romHash: "5dfb15eee3c57bbca80f485f68442e5f7c6bc5e4",
});

const voiceSource = `
ROM_START( voice )
    ROM_REGION( 0x1000, "maincpu", 0 )
    ROM_LOAD( "program", 0, 0x1000, SHA1(1111111111111111111111111111111111111111) )
    ROM_REGION( 0x8000, "adpcm", 0 )
    ROM_LOAD( "msm6373", 0, 0x8000, NO_DUMP )
ROM_END
`;
assert.strictEqual(parseRom(voiceSource, "voice")?.auxRom, undefined);
assert.throws(
  () =>
    parseRom(
      voiceSource.replace("NO_DUMP", "SHA1(2222222222222222222222222222222222222222)"),
      "voice"
    ),
  /Unsupported non-screen ROM region adpcm/
);

const unknownSource = source.replace('"sfx"', '"mystery"');
assert.throws(
  () => parseRom(unknownSource, "nstarfox"),
  /Unsupported non-screen ROM region mystery/
);

const malformedSfx = source.replace(
  'ROM_REGION( 0x80, "sfx", 0 )',
  'ROM_REGION( 0x100, "sfx", 0 )'
);
assert.throws(
  () => parseRom(malformedSfx, "nstarfox"),
  /must be a dumped 0x80-byte load/
);

console.log("ROM parser tests passed");
