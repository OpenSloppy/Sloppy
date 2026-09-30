import React, { useEffect, useState } from "react";
import { fetchProjects } from "../../../api";
import { fetchProactiveReviewProviders } from "../../../shared/api/coreApi";
import { defaultProactiveSettings, type HeartbeatSettings } from "../../../shared/api/proactivity";
import { AggregatedModelPicker } from "../../config/components/AggregatedModelPicker";
import type { AggregatedModelOption } from "../utils/aggregateProviderModels";
import "./proactivitySettings.css";

export function ProactivitySettingsFields({ heartbeat, onChange, models, disabled }: {
  heartbeat: HeartbeatSettings; onChange: (field: string, value: any) => void;
  models: AggregatedModelOption[]; disabled: boolean;
}) {
  const [projects, setProjects] = useState<any[]>([]);
  const [providers, setProviders] = useState<Array<{ id: string; displayName: string }>>([]);
  const [error, setError] = useState("");
  const [projectSearch, setProjectSearch] = useState("");
  const settings = { ...defaultProactiveSettings(), ...heartbeat.proactive };
  const visibleProjects = projects.filter((project) =>
    `${project.name} ${project.id}`.toLowerCase().includes(projectSearch.trim().toLowerCase())
  );
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
  return <div className="proactivity-settings-fields">
    <section className="proactivity-settings-panel">
      <h4>Behavior</h4>
      <div className="agent-config-reasoning-options" role="group" aria-label="Behavior">
        {["checklist", "proactive"].map((mode) => <button type="button" key={mode} disabled={disabled}
          className="agent-config-reasoning-option" aria-pressed={heartbeat.mode === mode}
          onClick={() => { onChange("mode", mode); onChange("intervalMinutes", mode === "proactive" ? 30 : 5); }}>
          {mode === "proactive" ? "Proactive attention" : "Checklist"}
        </button>)}
      </div>
    </section>
    {heartbeat.mode === "proactive" && <>
      <section className="proactivity-settings-panel">
        <AggregatedModelPicker label="Deep review model" value={settings.analysisModel} onChange={(value) => update("analysisModel", value)}
          aggregatedModels={models} disabled={disabled} hint="Used when a situation needs a closer look. Reviews only propose actions." />
      </section>
      <section className="proactivity-settings-panel">
        <div className="proactivity-settings-heading"><h4>Projects to watch</h4><span>{settings.projectIds.length} selected</span></div>
        {projects.length > 8 && <input className="proactivity-project-search" type="search" aria-label="Filter projects" placeholder="Filter projects…"
          value={projectSearch} onChange={(event) => setProjectSearch(event.target.value)} />}
        <div className="proactivity-source-list" role="group" aria-label="Projects to watch">
          {visibleProjects.map((project) => <label className="proactivity-source-option" key={project.id}>
            <input type="checkbox" checked={settings.projectIds.includes(project.id)} disabled={disabled}
              onChange={() => toggle("projectIds", project.id)} /><span>{project.name}</span>
          </label>)}
          {!visibleProjects.length && <span className="proactivity-settings-empty">{projects.length ? "No matching projects." : "No projects available."}</span>}
        </div>
      </section>
      <section className="proactivity-settings-panel">
        <div className="proactivity-settings-heading"><h4>Pull requests</h4><span>{settings.reviewProviderIds.length} selected</span></div>
        <div className="proactivity-source-list is-providers" role="group" aria-label="Review providers">
          {providers.map((provider) => <label className="proactivity-source-option" key={provider.id}>
            <input type="checkbox" checked={settings.reviewProviderIds.includes(provider.id)} disabled={disabled}
              onChange={() => toggle("reviewProviderIds", provider.id)} /><span>{provider.displayName}</span>
          </label>)}
          {!providers.length && <span className="proactivity-settings-empty">Connect a review provider to watch PRs.</span>}
        </div>
        <p className="proactivity-settings-note">Your authored PRs and requests for your review.</p>
      </section>
      <section className="proactivity-settings-panel">
        <h4>Notification hours</h4>
        <div className="proactivity-time-grid">
          <label className="proactivity-settings-field">From<div className="proactivity-hour-field">
            <input type="number" min={0} max={23} value={String(settings.notificationStartHour).padStart(2, "0")} disabled={disabled}
              onChange={(event) => update("notificationStartHour", Number(event.target.value))} /><span>:00</span>
          </div></label>
          <label className="proactivity-settings-field">Until<div className="proactivity-hour-field">
            <input type="number" min={1} max={24} value={String(settings.notificationEndHour).padStart(2, "0")} disabled={disabled}
              onChange={(event) => update("notificationEndHour", Number(event.target.value))} /><span>:00</span>
          </div></label>
        </div>
        <label className="proactivity-settings-field">Time zone
          <input className="proactivity-timezone" value={settings.timeZone} disabled={disabled}
            onChange={(event) => update("timeZone", event.target.value)} />
        </label>
        <p className="proactivity-settings-note">Findings collected overnight are delivered together when notification hours begin.</p>
      </section>
      {error && <p className="proactivity-settings-error" role="alert">{error}</p>}
    </>}
  </div>;
}
