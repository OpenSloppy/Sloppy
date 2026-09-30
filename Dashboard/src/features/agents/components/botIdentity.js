export const BOT_SHAPES = ["circle", "triangle", "diamond", "square"];

export function botShapeForAgent(agentId = "sloppy") {
  let seed = 2166136261;
  for (const byte of new TextEncoder().encode(agentId)) {
    seed = Math.imul(seed ^ byte, 16777619) >>> 0;
  }
  return BOT_SHAPES[seed % BOT_SHAPES.length];
}

export function botImageForAgent(agentId = "sloppy") {
  return `/pets/bots/bot-${botShapeForAgent(agentId)}.png`;
}

export const BOT_PALETTES = [
  { id: "mint", body: "#42c9b5", eyes: "#fff9ed" },
  { id: "violet", body: "#9c8fff", eyes: "#fff9ed" },
  { id: "coral", body: "#ff8a65", eyes: "#fff7e7" },
  { id: "amber", body: "#f4c657", eyes: "#473023" },
  { id: "sky", body: "#60b9ec", eyes: "#f6fbff" },
  { id: "rose", body: "#f295bb", eyes: "#493048" },
  { id: "lime", body: "#acd66b", eyes: "#294732" },
  { id: "graphite", body: "#636b82", eyes: "#faf7ee" }
];

export function botPaletteForAgent(agentId = "sloppy", paletteId) {
  const persisted = BOT_PALETTES.find(item => item.id === paletteId);
  if (persisted) return persisted;
  let seed = 2166136261;
  for (const byte of new TextEncoder().encode(agentId)) seed = Math.imul(seed ^ byte, 16777619) >>> 0;
  return BOT_PALETTES[(seed >>> 8) % BOT_PALETTES.length];
}

export function botEyePose(emotion) {
  const pose = { scaleX: 1, leftY: 1, rightY: 1, leftRotation: 0, rightRotation: 0, smiling: false };
  switch (emotion) {
    case "happy": pose.smiling = true; break;
    case "surprised": pose.scaleX = 1.25; pose.leftY = pose.rightY = 1.3; break;
    case "angry": pose.scaleX = 1.4; pose.leftY = pose.rightY = 0.3; pose.leftRotation = -0.38; pose.rightRotation = 0.38; break;
    case "error": pose.scaleX = 1.25; pose.leftY = pose.rightY = 0.35; pose.leftRotation = 0.18; pose.rightRotation = -0.18; break;
    case "thinking": pose.leftY = 0.65; break;
    case "needsInput": pose.leftY = 1.2; pose.rightY = 0.8; break;
  }
  return pose;
}
