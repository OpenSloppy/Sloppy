import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { BOT_SHAPES, botShapeForAgent, botImageForAgent, BOT_PALETTES, botPaletteForAgent, botEyePose } from "../src/features/agents/components/botIdentity.js";

const dashboardRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

test("bot identity agrees with Swift UTF-8 fixtures", () => {
  for (const [id, shape] of [["a", "circle"], ["b", "triangle"], ["c", "diamond"], ["d", "square"], ["研究", "circle"], ["sloppy", "diamond"]]) {
    assert.equal(botShapeForAgent(id), shape);
    assert.equal(botImageForAgent(id), `/pets/bots/bot-${shape}.png`);
  }
});

test("the same PNG catalog is bundled in the native client", () => {
  for (const shape of BOT_SHAPES) {
    const name = `bot-${shape}.png`;
    const png = readFileSync(join(dashboardRoot, "public/pets/bots", name));
    assert.deepEqual(png, readFileSync(join(dashboardRoot, "../ClientNative/Sources/SloppyClientUI/Resources/Bots", name)));
    assert.equal(png.readUInt32BE(12), 0x49484452);
    assert.equal(png[25], 6); // RGBA PNG.
  }
  assert.equal(existsSync(join(dashboardRoot, "public/pets/presets")), false);
  assert.equal(existsSync(join(dashboardRoot, "scripts/generate-pet-presets.mjs")), false);
});

test("persisted colors are independent of body shape and emotions change the eyes", () => {
  for (const palette of BOT_PALETTES) {
    for (const id of ["a", "b", "c", "d"]) assert.equal(botPaletteForAgent(id, palette.id).id, palette.id);
  }
  assert.equal(botEyePose("happy").smiling, true);
  assert.ok(botEyePose("surprised").scaleX > 1);
  assert.ok(botEyePose("angry").leftRotation < 0);
  assert.ok(botEyePose("error").leftY < 1);
});
