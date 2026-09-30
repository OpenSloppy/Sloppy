import React, { useEffect, useMemo, useState, useCallback, useRef } from "react";
import {
  fetchSkillsRegistry,
  fetchAgentSkills,
  installAgentSkill,
  uninstallAgentSkill
} from "../../../api";

interface SkillInfo {
  id: string;
  owner: string;
  repo: string;
  name: string;
  description?: string;
  installs: number;
  githubUrl: string;
}

interface InstalledSkill {
  id: string;
  owner: string;
  repo: string;
  name: string;
  description?: string;
  installedAt: string;
  localPath: string;
  userInvocable?: boolean;
  allowedTools?: string[];
  context?: string;
  agent?: string;
}

interface AgentSkillsTabProps {
  agentId: string;
}

type TabType = "registry" | "installed";

const SKILL_SORT_OPTIONS = [
  { value: "installs", label: "All Time" },
  { value: "trending", label: "Trending" },
  { value: "recent", label: "Recent" }
];

function SkillSortPicker({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const selectedIndex = Math.max(0, SKILL_SORT_OPTIONS.findIndex((option) => option.value === value));

  useEffect(() => {
    if (open) optionRefs.current[selectedIndex]?.focus();
  }, [open, selectedIndex]);

  return <div className="actor-team-search-wrap skills-sort" onBlur={(event) => {
    if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setOpen(false);
  }}>
    <button type="button" className="actor-team-search" ref={triggerRef}
      aria-label={`Sort skills: ${SKILL_SORT_OPTIONS[selectedIndex].label}`}
      aria-haspopup="menu" aria-expanded={open} aria-controls={open ? "skills-sort-menu" : undefined}
      onClick={() => setOpen(!open)} onKeyDown={(event) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); setOpen(true); }
      }}>
      {SKILL_SORT_OPTIONS[selectedIndex].label}
      <span className="material-symbols-rounded" aria-hidden>expand_more</span>
    </button>
    {open && <ul className="actor-team-dropdown" id="skills-sort-menu" role="menu" aria-label="Sort skills">
      {SKILL_SORT_OPTIONS.map((option, index) => <li key={option.value} role="none">
        <button type="button" role="menuitemradio" aria-checked={value === option.value}
          className={`actor-team-dropdown-item ${value === option.value ? "selected" : ""}`}
          ref={(element) => { optionRefs.current[index] = element; }}
          onClick={() => { onChange(option.value); setOpen(false); triggerRef.current?.focus(); }}
          onKeyDown={(event) => {
            if (event.key === "Escape") { event.preventDefault(); setOpen(false); triggerRef.current?.focus(); }
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              optionRefs.current[(index + (event.key === "ArrowDown" ? 1 : -1) + SKILL_SORT_OPTIONS.length) % SKILL_SORT_OPTIONS.length]?.focus();
            }
          }}>
          <span className="actor-team-dropdown-name">{option.label}</span>
          {value === option.value && <span className="material-symbols-rounded" aria-hidden>check</span>}
        </button>
      </li>)}
    </ul>}
  </div>;
}

function formatInstalls(count: number): string {
  if (count >= 1000000) {
    return `${(count / 1000000).toFixed(1)}M`;
  }
  if (count >= 1000) {
    return `${(count / 1000).toFixed(1)}k`;
  }
  return String(count);
}

function parseGitHubSkillInput(value: string): { owner: string; repo: string } | null {
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }

  const normalizedURLInput = trimmed
    .replace(/^https:\/github\.com\//i, "https://github.com/")
    .replace(/^http:\/github\.com\//i, "http://github.com/")
    .replace(/^git@github\.com:/i, "https://github.com/")
    .replace(/^ssh:\/\/git@github\.com\//i, "https://github.com/");

  if (/^https?:\/\//i.test(normalizedURLInput)) {
    try {
      const url = new URL(normalizedURLInput);
      const hostname = url.hostname.toLowerCase();
      if (hostname !== "github.com" && hostname !== "www.github.com") {
        return null;
      }
      const segments = url.pathname.split("/").filter(Boolean);
      if (segments.length < 2) {
        return null;
      }

      const owner = segments[0];
      const repo = segments[1].replace(/\.git$/i, "");
      return owner && repo ? { owner, repo } : null;
    } catch {
      return null;
    }
  }

  const segments = trimmed
    .replace(/^\/+/, "")
    .split("/")
    .filter(Boolean);

  if (segments.length < 2) {
    return null;
  }

  const owner = segments[0];
  const repo = segments[1].replace(/\.git$/i, "");
  return owner && repo ? { owner, repo } : null;
}

function SkillCard({
  skill,
  isInstalled,
  isInstalling,
  onInstall,
  onUninstall
}: {
  skill: SkillInfo;
  isInstalled: boolean;
  isInstalling: boolean;
  onInstall: () => void;
  onUninstall: () => void;
}) {
  const descriptionText = typeof skill.description === "string" ? skill.description.trim() : "";
  return (
    <div className="skill-card hover-levitate">
      <div className="skill-card-header">
        <h4 className="skill-name">{skill.name}</h4>
        <span className="skill-owner">{skill.owner}/{skill.repo}</span>
      </div>
      <p className={`skill-description ${descriptionText ? "" : "skill-description--missing"}`}>
        {descriptionText || "No description"}
      </p>
      <div className="skill-card-footer">
        <span className="skill-installs">{formatInstalls(skill.installs)} installs</span>
        <div className="skill-card-footer-buttons">
          <a
            href={skill.githubUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="skill-github-link-btn"
            title={`Open ${skill.owner}/${skill.repo} on GitHub`}
          >
            <span className="material-symbols-rounded" aria-hidden>
              open_in_new
            </span>
            <span className="skill-github-link-label">GitHub</span>
          </a>
          {isInstalled ? (
            <button
              type="button"
              className="skill-button skill-button-installed"
              aria-label={`Uninstall ${skill.name}`} title={`Uninstall ${skill.name}`}
              onClick={onUninstall}
              disabled={isInstalling}
            >
              <span className="material-symbols-rounded">check</span>
            </button>
          ) : (
            <button
              type="button"
              className="skill-button skill-button-install"
              aria-label={`Install ${skill.name}`} title={`Install ${skill.name}`}
              onClick={onInstall}
              disabled={isInstalling}
            >
              {isInstalling ? (
                <span className="material-symbols-rounded">hourglass_empty</span>
              ) : (
                <span className="material-symbols-rounded">download</span>
              )}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function InstalledSkillCard({
  skill,
  isUninstalling,
  onUninstall
}: {
  skill: InstalledSkill;
  isUninstalling: boolean;
  onUninstall: () => void;
}) {
  const hasMetadata = (skill.userInvocable === false) ||
    (skill.allowedTools && skill.allowedTools.length > 0) ||
    skill.context ||
    skill.agent;

  const descriptionText = typeof skill.description === "string" ? skill.description.trim() : "";

  const githubRepoUrl = `https://github.com/${skill.owner}/${skill.repo}`;

  return (
    <div className="skill-card hover-levitate">
      <div className="skill-card-header">
        <h4 className="skill-name">{skill.name}</h4>
        <span className="skill-owner">{skill.owner}/{skill.repo}</span>
      </div>
      <p className={`skill-description ${descriptionText ? "" : "skill-description--missing"}`}>
        {descriptionText || "No description"}
      </p>
      {hasMetadata && (
        <div className="skill-metadata">
          {skill.userInvocable === false && (
            <span className="skill-badge skill-badge-muted">model-only</span>
          )}
          {skill.context === "fork" && (
            <span className="skill-badge skill-badge-context">
              fork{skill.agent ? `: ${skill.agent}` : ""}
            </span>
          )}
          {skill.allowedTools && skill.allowedTools.length > 0 && (
            <span className="skill-badge skill-badge-tools" title={skill.allowedTools.join(", ")}>
              {skill.allowedTools.length} allowed tool{skill.allowedTools.length > 1 ? "s" : ""}
            </span>
          )}
        </div>
      )}
      <div className="skill-card-footer">
        <span className="skill-installs">
          Installed {new Date(skill.installedAt).toLocaleDateString()}
        </span>
        <div className="skill-card-footer-buttons">
          <a
            href={githubRepoUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="skill-github-link-btn"
            title={`Open ${skill.owner}/${skill.repo} on GitHub`}
          >
            <span className="material-symbols-rounded" aria-hidden>
              open_in_new
            </span>
            <span className="skill-github-link-label">GitHub</span>
          </a>
          <button
            type="button"
            className="skill-button skill-button-uninstall"
            aria-label={`Uninstall ${skill.name}`} title={`Uninstall ${skill.name}`}
            onClick={onUninstall}
            disabled={isUninstalling}
          >
            {isUninstalling ? (
              <span className="material-symbols-rounded">hourglass_empty</span>
            ) : (
              <span className="material-symbols-rounded">delete</span>
            )}
          </button>
        </div>
      </div>
    </div>
  );
}

const PAGE_SIZE = 20;

export function AgentSkillsTab({ agentId }: AgentSkillsTabProps) {
  const [activeTab, setActiveTab] = useState<TabType>("registry");
  // Input value (updates on every keystroke)
  const [searchInput, setSearchInput] = useState("");
  // Debounced value (used for API calls)
  const [searchQuery, setSearchQuery] = useState("");
  const [sortBy, setSortBy] = useState("installs");
  const [registrySkills, setRegistrySkills] = useState<SkillInfo[]>([]);
  const [registryTotal, setRegistryTotal] = useState(0);
  const [registryOffset, setRegistryOffset] = useState(0);
  const [isLoadingRegistry, setIsLoadingRegistry] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [installedSkills, setInstalledSkills] = useState<InstalledSkill[]>([]);
  const [isLoadingInstalled, setIsLoadingInstalled] = useState(false);
  const [installingSkillId, setInstallingSkillId] = useState<string | null>(null);
  const [uninstallingSkillId, setUninstallingSkillId] = useState<string | null>(null);
  const [githubInput, setGithubInput] = useState("");
  const [localPathInput, setLocalPathInput] = useState("");
  const [isInstallingFromGithub, setIsInstallingFromGithub] = useState(false);
  const [isInstallingFromLocal, setIsInstallingFromLocal] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Debounce search input → searchQuery
  useEffect(() => {
    const timer = setTimeout(() => setSearchQuery(searchInput), 300);
    return () => clearTimeout(timer);
  }, [searchInput]);

  // Load registry skills (fresh page)
  const loadRegistrySkills = useCallback(async (search: string, sort: string) => {
    console.debug("[AgentSkillsTab] loadRegistrySkills called:", { search: search || null, sort, offset: 0 });
    setIsLoadingRegistry(true);
    setRegistryOffset(0);
    try {
      const response = await fetchSkillsRegistry(search || undefined, sort, PAGE_SIZE, 0);
      const skillsCount = response && Array.isArray(response.skills) ? (response.skills as unknown[]).length : 0;
      const total = response && typeof response.total === "number" ? response.total : skillsCount;
      console.debug("[AgentSkillsTab] loadRegistrySkills result:", { skillsCount, total, raw: response });
      if (response && Array.isArray(response.skills)) {
        setRegistrySkills(response.skills as SkillInfo[]);
        setRegistryTotal(total);
      } else {
        setRegistrySkills([]);
        setRegistryTotal(0);
      }
    } catch (err) {
      console.debug("[AgentSkillsTab] loadRegistrySkills error:", err);
      setRegistrySkills([]);
      setRegistryTotal(0);
    } finally {
      setIsLoadingRegistry(false);
    }
  }, []);

  // Load more (append next page)
  const loadMoreSkills = useCallback(async (search: string, sort: string, offset: number) => {
    setIsLoadingMore(true);
    try {
      const response = await fetchSkillsRegistry(search || undefined, sort, PAGE_SIZE, offset);
      if (response && Array.isArray(response.skills)) {
        setRegistrySkills(prev => [...prev, ...(response.skills as SkillInfo[])]);
        setRegistryTotal(typeof response.total === "number" ? response.total : 0);
        setRegistryOffset(offset);
      }
    } catch {
      // ignore
    } finally {
      setIsLoadingMore(false);
    }
  }, []);

  // Load installed skills
  const loadInstalledSkills = useCallback(async () => {
    setIsLoadingInstalled(true);
    try {
      const response = await fetchAgentSkills(agentId);
      if (response && Array.isArray(response.skills)) {
        setInstalledSkills(response.skills as InstalledSkill[]);
      } else {
        setInstalledSkills([]);
      }
    } catch {
      setInstalledSkills([]);
    } finally {
      setIsLoadingInstalled(false);
    }
  }, [agentId]);

  // Reload registry when debounced query or sort changes
  useEffect(() => {
    loadRegistrySkills(searchQuery, sortBy);
  }, [searchQuery, sortBy, loadRegistrySkills]);

  // Initial installed load
  useEffect(() => {
    loadInstalledSkills();
  }, [loadInstalledSkills]);

  const handleInstall = async (skill: SkillInfo) => {
    setInstallingSkillId(skill.id);
    setError(null);
    try {
      const result = await installAgentSkill(agentId, { owner: skill.owner, repo: skill.repo });
      if (result) {
        await loadInstalledSkills();
      } else {
        setError(`Failed to install ${skill.name}`);
      }
    } catch (err) {
      setError(`Failed to install ${skill.name}`);
    } finally {
      setInstallingSkillId(null);
    }
  };

  const handleUninstall = async (skillId: string) => {
    setUninstallingSkillId(skillId);
    setError(null);
    try {
      const success = await uninstallAgentSkill(agentId, skillId);
      if (success) {
        await loadInstalledSkills();
      } else {
        setError(`Failed to uninstall skill`);
      }
    } catch (err) {
      setError(`Failed to uninstall skill`);
    } finally {
      setUninstallingSkillId(null);
    }
  };

  const handleInstallFromGithub = async () => {
    const trimmed = githubInput.trim();
    if (!trimmed) return;

    const parsed = parseGitHubSkillInput(trimmed);
    if (!parsed) {
      setError("Please use owner/repo or a GitHub repository URL");
      return;
    }

    const { owner, repo } = parsed;
    setIsInstallingFromGithub(true);
    setError(null);

    try {
      const result = await installAgentSkill(agentId, { owner, repo });
      if (result) {
        setGithubInput("");
        await loadInstalledSkills();
        setActiveTab("installed");
      } else {
        setError(`Failed to install ${owner}/${repo}`);
      }
    } catch (err) {
      setError(`Failed to install ${owner}/${repo}`);
    } finally {
      setIsInstallingFromGithub(false);
    }
  };

  const handleInstallFromLocal = async () => {
    const localPath = localPathInput.trim();
    if (!localPath) return;

    setIsInstallingFromLocal(true);
    setError(null);

    try {
      const result = await installAgentSkill(agentId, { localPath });
      if (result) {
        setLocalPathInput("");
        await loadInstalledSkills();
        setActiveTab("installed");
      } else {
        setError(`Failed to install local skill from ${localPath}`);
      }
    } catch (err) {
      setError(`Failed to install local skill from ${localPath}`);
    } finally {
      setIsInstallingFromLocal(false);
    }
  };

  const installedSkillIds = useMemo(() => {
    return new Set(installedSkills.map(s => s.id));
  }, [installedSkills]);

  const filteredRegistrySkills = useMemo(() => registrySkills, [registrySkills]);

  return (
    <section className="entry-editor-card agent-content-card agent-skills">
      <div className="skills-header">
        <h3>Skills</h3>
        <a
          href="https://skills.sh"
          target="_blank"
          rel="noopener noreferrer"
          className="skills-external-link"
        >
          skills.sh
          <span className="material-symbols-rounded">open_in_new</span>
        </a>
      </div>

      {/* Tabs */}
      <div className="skills-tabs agent-config-reasoning-options" role="group" aria-label="Skills view">
        <button
          type="button"
          className="agent-config-reasoning-option" aria-pressed={activeTab === "registry"}
          onClick={() => setActiveTab("registry")}
        >
          Browse Registry
        </button>
        <button
          type="button"
          className="agent-config-reasoning-option" aria-pressed={activeTab === "installed"}
          onClick={() => setActiveTab("installed")}
        >
          Installed ({installedSkills.length})
        </button>
      </div>

      {error && (
        <div className="skills-error">
          <span className="material-symbols-rounded">error</span>
          {error}
        </div>
      )}

      {activeTab === "registry" && (
        <>
          {/* Search and Filter */}
          <div className="skills-toolbar">
            <div className="skills-search">
              <span className="material-symbols-rounded">search</span>
              <input
                type="text"
                placeholder="Search skills..."
                aria-label="Search skills"
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
              />
            </div>
            <SkillSortPicker value={sortBy} onChange={setSortBy} />
          </div>

          <div className="skills-install-sources">
            {/* Install from GitHub */}
            <div className="skills-github-section">
              <h4>Install from GitHub</h4>
              <p className="skills-github-description">
                Install any skill from a GitHub repository
              </p>
              <div className="skills-github-input-group">
                <input
                  type="text"
                  placeholder="owner/repo or https://github.com/owner/repo"
                  aria-label="GitHub repository"
                  value={githubInput}
                  onChange={(e) => setGithubInput(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && handleInstallFromGithub()}
                />
                <button
                  type="button"
                  className="skills-install-btn"
                  onClick={handleInstallFromGithub}
                  disabled={isInstallingFromGithub || !githubInput.trim()}
                >
                  {isInstallingFromGithub ? (
                    <span className="material-symbols-rounded">hourglass_empty</span>
                  ) : (
                    <>
                      <span className="material-symbols-rounded">download</span>
                      Install
                    </>
                  )}
                </button>
              </div>
            </div>

            {/* Install from local directory */}
            <div className="skills-github-section skills-local-section">
              <h4>Install from local directory</h4>
              <p className="skills-github-description">
                Copy a local skill directory that contains SKILL.md into this agent's skills.
              </p>
              <div className="skills-github-input-group">
                <input
                  type="text"
                  placeholder="/absolute/path/to/my-skill"
                  aria-label="Local skill directory"
                  value={localPathInput}
                  onChange={(e) => setLocalPathInput(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && handleInstallFromLocal()}
                />
                <button
                  type="button"
                  className="skills-install-btn"
                  onClick={handleInstallFromLocal}
                  disabled={isInstallingFromLocal || !localPathInput.trim()}
                >
                  {isInstallingFromLocal ? (
                    <span className="material-symbols-rounded">hourglass_empty</span>
                  ) : (
                    <>
                      <span className="material-symbols-rounded">folder_open</span>
                      Install local
                    </>
                  )}
                </button>
              </div>
            </div>
          </div>

          {/* Skills Grid */}
          <div className="skills-section-title">
            {sortBy === "trending" ? "Trending Skills" : sortBy === "recent" ? "Recent Skills" : "All Time Skills"}
            <span className="skills-count">{registryTotal > 0 ? `${registryTotal} skills` : `${filteredRegistrySkills.length} skills`}</span>
          </div>

          {isLoadingRegistry ? (
            <div className="skills-loading">
              <span className="material-symbols-rounded">hourglass_empty</span>
              Loading skills...
            </div>
          ) : filteredRegistrySkills.length === 0 ? (
            <div className="skills-empty">
              {searchInput
                ? "No skills found matching your search."
                : "No skills available."}
            </div>
          ) : (
            <>
              <div className="skills-grid">
                {filteredRegistrySkills.map((skill) => (
                  <SkillCard
                    key={skill.id}
                    skill={skill}
                    isInstalled={installedSkillIds.has(skill.id)}
                    isInstalling={installingSkillId === skill.id}
                    onInstall={() => handleInstall(skill)}
                    onUninstall={() => handleUninstall(skill.id)}
                  />
                ))}
              </div>
              {registrySkills.length < registryTotal && (
                <div className="skills-load-more">
                  <button
                    type="button"
                    className="skills-load-more-btn"
                    onClick={() => loadMoreSkills(searchQuery, sortBy, registryOffset + PAGE_SIZE)}
                    disabled={isLoadingMore}
                  >
                    {isLoadingMore ? (
                      <><span className="material-symbols-rounded">hourglass_empty</span> Loading...</>
                    ) : (
                      `Load more (${registryTotal - registrySkills.length} remaining)`
                    )}
                  </button>
                </div>
              )}
            </>
          )}
        </>
      )}

      {activeTab === "installed" && (
        <>
          {isLoadingInstalled ? (
            <div className="skills-loading">
              <span className="material-symbols-rounded">hourglass_empty</span>
              Loading installed skills...
            </div>
          ) : installedSkills.length === 0 ? (
            <div className="skills-empty">
              <p>No skills installed yet.</p>
              <button
                type="button"
                className="skills-browse-btn hover-levitate"
                onClick={() => setActiveTab("registry")}
              >
                Browse Registry
              </button>
            </div>
          ) : (
            <div className="skills-grid">
              {installedSkills.map((skill) => (
                <InstalledSkillCard
                  key={skill.id}
                  skill={skill}
                  isUninstalling={uninstallingSkillId === skill.id}
                  onUninstall={() => handleUninstall(skill.id)}
                />
              ))}
            </div>
          )}
        </>
      )}
    </section>
  );
}
