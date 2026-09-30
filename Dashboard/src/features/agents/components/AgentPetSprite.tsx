import React, { useEffect, useId, useRef, useState } from "react";
import { botEyePose, botImageForAgent, botPaletteForAgent, botShapeForAgent } from "./botIdentity";

type BotProps = {
  agentId?: string;
  paletteId?: string;
  className?: string;
  animated?: boolean;
  state?: string;
};

function BotArtwork({ agentId = "sloppy", paletteId, animated = false, state = "idle" }: BotProps) {
  const filterId = `bot-color-${useId().replace(/:/g, "")}`;
  const [gaze, setGaze] = useState({ x: 0, y: 0 });
  const [reaction, setReaction] = useState<string | null>(null);
  const pokes = useRef<number[]>([]);
  useEffect(() => {
    if (!reaction) return;
    const timer = window.setTimeout(() => setReaction(null), reaction === "angry" ? 2200 : 1500);
    return () => window.clearTimeout(timer);
  }, [reaction]);
  const palette = botPaletteForAgent(agentId, paletteId);
  const shape = botShapeForAgent(agentId);
  const emotion = state === "error" || state === "needsInput" ? state : reaction || state;
  const pose = botEyePose(emotion);
  const rgb = [1, 3, 5].map(index => parseInt(palette.body.slice(index, index + 2), 16) / 255);
  const matrix = `${rgb[0]} 0 0 0 0 0 ${rgb[1]} 0 0 0 0 0 ${rgb[2]} 0 0 0 0 0 1 0`;
  const width = shape === "circle" ? 1.9 : 2.3;
  const height = shape === "circle" ? 4.2 : 2.3;
  const baseline = shape === "triangle" ? 0.25 : 1.2;
  const eyeGaze = emotion === "thinking" ? { x: -0.6, y: -0.7 } : emotion === "error" ? { x: 0, y: 0.45 } : gaze;

  function lookAt(event: React.PointerEvent<SVGSVGElement>) {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const bounds = event.currentTarget.getBoundingClientRect();
    const x = (event.clientX - bounds.left) / Math.max(1, bounds.width) * 24 - 12;
    const y = (event.clientY - bounds.top) / Math.max(1, bounds.height) * 24 - 12;
    const distance = Math.max(1, Math.hypot(x, y));
    setGaze({ x: x / distance * 0.9, y: y / distance * 0.75 });
  }

  function poke() {
    if (state === "error" || state === "needsInput") return;
    const now = performance.now();
    pokes.current = [...pokes.current.filter(time => now - time < 1350), now];
    setReaction(pokes.current.length === 1 ? "surprised" : pokes.current.length === 2 ? "happy" : "angry");
    if (pokes.current.length >= 3) pokes.current = [];
  }

  return (
    <svg viewBox="0 0 24 24" className={animated ? "agent-bot-image is-animated" : "agent-bot-image"}
      data-emotion={emotion} aria-hidden="true"
      onPointerMove={animated ? lookAt : undefined}
      onPointerLeave={animated ? () => setGaze({ x: 0, y: 0 }) : undefined}
      onPointerDown={animated ? poke : undefined}>
      <defs><filter id={filterId} colorInterpolationFilters="sRGB"><feColorMatrix type="matrix" values={matrix} /></filter></defs>
      <image href={botImageForAgent(agentId)} width="24" height="24" filter={`url(#${filterId})`} />
      {[0, 1].map(index => {
        const rotation = -(index === 0 ? pose.leftRotation : pose.rightRotation) * 180 / Math.PI;
        const shapeRotation = !pose.smiling && shape === "diamond" ? 45 : 0;
        return <g key={index} className="agent-bot-gaze"
          transform={`translate(${12 + (index === 0 ? -2.45 : 2.45) + eyeGaze.x} ${12 - baseline + eyeGaze.y})`}>
          <g className={animated && !pose.smiling ? "agent-bot-eye-blink" : ""}>
            <g className="agent-bot-eye" transform={`rotate(${rotation + shapeRotation}) scale(${pose.scaleX} ${index === 0 ? pose.leftY : pose.rightY})`}>
              {pose.smiling ? <path d={`M ${-width / 2} 0 Q 0 -1.3 ${width / 2} 0`} fill="none" stroke={palette.eyes} strokeWidth="0.65" strokeLinecap="round" />
                : shape === "triangle" ? <circle r={width / 2} fill={palette.eyes} />
                : <rect x={-width / 2} y={-height / 2} width={width} height={height} rx={shape === "circle" ? width / 2 : 0.5} fill={palette.eyes} />}
            </g>
          </g>
        </g>;
      })}
    </svg>
  );
}

export function AgentPetSprite(props: BotProps) {
  return <div className={`agent-pet-sprite ${props.className || ""}`.trim()} aria-hidden="true">
    <BotArtwork {...props} animated={props.animated !== false} />
  </div>;
}

export function AgentPetIcon(props: BotProps) {
  return <div className={`agent-pet-icon ${props.className || ""}`.trim()} aria-hidden="true">
    <BotArtwork {...props} animated={false} />
  </div>;
}
