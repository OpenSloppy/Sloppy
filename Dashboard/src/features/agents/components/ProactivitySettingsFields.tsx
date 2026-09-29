import React, { useEffect, useState } from "react";
import { fetchProjects } from "../../../api";
import { fetchProactiveReviewProviders } from "../../../shared/api/coreApi";
import { defaultProactiveSettings, type HeartbeatSettings } from "../../../shared/api/proactivity";
import { AggregatedModelPicker } from "../../config/components/AggregatedModelPicker";
import type { AggregatedModelOption } from "../utils/aggregateProviderModels";

export function ProactivitySettingsFields({ heartbeat, onChange, models, disabled }: {
  heartbeat: HeartbeatSettings; onChange: (field: string, value: any) => void;
  models: AggregatedModelOption[]; disabled: boolean;
}) {
  const [projects, setProjects] = useState<any[]>([]);
  const [providers, setProviders] = useState<Array<{ id: string; displayName: string }>>([]);
  const [error, setError] = useState("");
  const settings = { ...defaultProactiveSettings(), ...heartbeat.proactive };
  useEffect(() => {
    let cancelled = false;
    Promise.all([fetchProjects(), fetchProactiveReviewProviders()]).then(([projects, providers]) => {
      if (cancelled) return;
      if (!projects) throw new Error("Projects could not be loaded.");
      setProjects(projects.filter((project) => !project.isArchived)); setProviders(providers);
    }).catch((error) => { if (!cancelled) setError(String(error.message || error)); });
    return () => { cancelled = true; };
  }, []);
  const update = (field: string, value: unknown) => onChange("proactive", { ...settings, [field]: value });
  const toggle = (field: "projectIds" | "reviewProviderIds", id: string) =>
    update(field, settings[field].includes(id) ? settings[field].filter((value) => value !== id) : [...settings[field], id]);
  return <div className="entry-form-grid" style={{ marginTop: 12 }}>
    <div style={{ gridColumn: "1 / -1" }}>
      <span className="entry-form-hint">Behavior</span>
      <div className="agent-config-reasoning-options">
        {["checklist", "proactive"].map((mode) => <button type="button" key={mode} disabled={disabled}
          className={`agent-config-reasoning-option ${heartbeat.mode === mode ? "active" : ""}`}
          onClick={() => { onChange("mode", mode); onChange("intervalMinutes", mode === "proactive" ? 30 : 5); }}>
          {mode === "proactive" ? "Proactive attention" : "Checklist"}
        </button>)}
      </div>
    </div>
    {heartbeat.mode === "proactive" && <>
      <AggregatedModelPicker label="Deep review model" value={settings.analysisModel} onChange={(value) => update("analysisModel", value)}
        aggregatedModels={models} disabled={disabled} hint="Used when a situation needs a closer look. Reviews only propose actions." />
      <fieldset style={{ gridColumn: "1 / -1" }} disabled={disabled}>
        <legend>Projects to watch</legend>
        {projects.map((project) => <label key={project.id} style={{ display: "flex", gap: 8 }}>
          <input type="checkbox" checked={settings.projectIds.includes(project.id)} onChange={() => toggle("projectIds", project.id)} />{project.name}
        </label>)}
        {!projects.length && <span className="entry-form-hint">No projects available.</span>}
      </fieldset>
      <fieldset style={{ gridColumn: "1 / -1" }} disabled={disabled}>
        <legend>Pull requests</legend>
        {providers.map((provider) => <label key={provider.id} style={{ display: "flex", gap: 8 }}>
          <input type="checkbox" checked={settings.reviewProviderIds.includes(provider.id)} onChange={() => toggle("reviewProviderIds", provider.id)} />{provider.displayName}
        </label>)}
        <span className="entry-form-hint">Your authored PRs and requests for your review.</span>
        {!providers.length && <span className="entry-form-hint">Connect a review provider to watch PRs.</span>}
      </fieldset>
      <label>Notifications from<input type="number" min={0} max={23} value={settings.notificationStartHour} disabled={disabled}
        onChange={(event) => update("notificationStartHour", Number(event.target.value))} /></label>
      <label>Notifications until<input type="number" min={1} max={24} value={settings.notificationEndHour} disabled={disabled}
        onChange={(event) => update("notificationEndHour", Number(event.target.value))} /></label>
      <label>Time zone<input value={settings.timeZone} disabled={disabled} onChange={(event) => update("timeZone", event.target.value)} /></label>
      <span className="entry-form-hint">Findings collected overnight are delivered together when notification hours begin.</span>
      {error && <p role="alert">{error}</p>}
    </>}
  </div>;
}
