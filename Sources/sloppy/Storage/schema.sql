CREATE TABLE IF NOT EXISTS channels (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    status TEXT NOT NULL,
    title TEXT NOT NULL,
    objective TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    message_type TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    task_id TEXT,
    branch_id TEXT,
    worker_id TEXT,
    payload_json TEXT NOT NULL,
    extensions_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_channel_created ON events(channel_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_task_created ON events(task_id, created_at DESC);

CREATE TABLE IF NOT EXISTS artifacts (
    id TEXT PRIMARY KEY,
    title TEXT,
    kind TEXT,
    media_type TEXT,
    content TEXT NOT NULL,
    preview_text TEXT,
    widget_size TEXT,
    widget_width INTEGER,
    widget_height INTEGER,
    widget_entry TEXT,
    bundle_path TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS published_sites (
    id TEXT PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    visibility TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    project_id TEXT,
    entry_file TEXT NOT NULL,
    bundle_path TEXT NOT NULL,
    revision INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_published_sites_owner_updated
    ON published_sites(owner_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS workspaces (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    cover TEXT,
    owner_id TEXT NOT NULL,
    project_id TEXT,
    revision INTEGER NOT NULL DEFAULT 0,
    is_archived INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_workspaces_project_updated ON workspaces(project_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_workspaces_archived_updated ON workspaces(is_archived, updated_at DESC);

CREATE TABLE IF NOT EXISTS workspace_members (
    workspace_id TEXT NOT NULL,
    principal_kind TEXT NOT NULL,
    principal_id TEXT NOT NULL,
    role TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(workspace_id, principal_kind, principal_id)
);

CREATE TABLE IF NOT EXISTS workspace_snapshots (
    workspace_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL,
    document_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS workspace_transactions (
    workspace_id TEXT NOT NULL,
    id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    transaction_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(workspace_id, id),
    UNIQUE(workspace_id, revision)
);

CREATE INDEX IF NOT EXISTS idx_workspace_transactions_revision
    ON workspace_transactions(workspace_id, revision);

CREATE TABLE IF NOT EXISTS workspace_templates (
    id TEXT PRIMARY KEY,
    visibility TEXT NOT NULL,
    owner_id TEXT,
    template_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS project_initiatives (
    id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    title TEXT NOT NULL,
    goal TEXT NOT NULL,
    phase TEXT NOT NULL,
    execution_mode TEXT NOT NULL,
    success_metrics_json TEXT NOT NULL DEFAULT '[]',
    constraints_json TEXT NOT NULL DEFAULT '[]',
    resume_point TEXT,
    blocker TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (project_id, id)
);

CREATE INDEX IF NOT EXISTS idx_project_initiatives_project ON project_initiatives(project_id, created_at DESC);

CREATE TABLE IF NOT EXISTS initiative_decision_packets (
    id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    initiative_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    rationale TEXT NOT NULL,
    tradeoffs_json TEXT NOT NULL DEFAULT '[]',
    requested_action TEXT NOT NULL,
    resume_point TEXT,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (project_id, id)
);

CREATE INDEX IF NOT EXISTS idx_initiative_decision_packets_initiative
    ON initiative_decision_packets(project_id, initiative_id, created_at DESC);

CREATE TABLE IF NOT EXISTS memory_bulletins (
    id TEXT PRIMARY KEY,
    headline TEXT NOT NULL,
    digest TEXT NOT NULL,
    items_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_entries (
    id TEXT PRIMARY KEY,
    class TEXT NOT NULL,
    kind TEXT NOT NULL,
    text TEXT NOT NULL,
    summary TEXT,
    scope_type TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    channel_id TEXT,
    project_id TEXT,
    agent_id TEXT,
    importance REAL NOT NULL DEFAULT 0.5,
    confidence REAL NOT NULL DEFAULT 0.7,
    source_type TEXT,
    source_id TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    expires_at TEXT,
    deleted_at TEXT
);

CREATE TABLE IF NOT EXISTS memory_edges (
    id TEXT PRIMARY KEY,
    from_memory_id TEXT NOT NULL,
    to_memory_id TEXT NOT NULL,
    relation TEXT NOT NULL,
    weight REAL NOT NULL DEFAULT 1.0,
    provenance TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_provider_outbox (
    id TEXT PRIMARY KEY,
    memory_id TEXT NOT NULL,
    op TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 0,
    next_retry_at TEXT NOT NULL,
    last_error TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_recall_log (
    id TEXT PRIMARY KEY,
    query TEXT NOT NULL,
    scope_type TEXT,
    scope_id TEXT,
    top_k INTEGER NOT NULL,
    result_ids_json TEXT NOT NULL,
    latency_ms INTEGER NOT NULL,
    created_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS memory_entries_fts USING fts5(
    id UNINDEXED,
    text,
    summary
);

CREATE INDEX IF NOT EXISTS idx_memory_entries_scope_time ON memory_entries(scope_type, scope_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_memory_entries_kind ON memory_entries(kind);
CREATE INDEX IF NOT EXISTS idx_memory_entries_class ON memory_entries(class);
CREATE INDEX IF NOT EXISTS idx_memory_entries_expires ON memory_entries(expires_at);
CREATE INDEX IF NOT EXISTS idx_memory_edges_from ON memory_edges(from_memory_id);
CREATE INDEX IF NOT EXISTS idx_memory_edges_to ON memory_edges(to_memory_id);
CREATE INDEX IF NOT EXISTS idx_memory_outbox_retry ON memory_provider_outbox(next_retry_at, attempt);

CREATE TABLE IF NOT EXISTS token_usage (
    id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    task_id TEXT,
    prompt_tokens INTEGER NOT NULL,
    completion_tokens INTEGER NOT NULL,
    total_tokens INTEGER NOT NULL,
    cached_input_tokens INTEGER NOT NULL DEFAULT 0,
    cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0,
    reasoning_tokens INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS semantic_decision_usage (
    id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    input_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    cost_usd REAL NOT NULL,
    cost_is_estimated INTEGER NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_semantic_decision_usage_created_at
ON semantic_decision_usage(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_semantic_decision_usage_channel_created_at
ON semantic_decision_usage(channel_id, created_at DESC);

CREATE TABLE IF NOT EXISTS tool_invocations (
    id TEXT PRIMARY KEY,
    project_id TEXT,
    task_id TEXT,
    agent_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    tool TEXT NOT NULL,
    ok INTEGER NOT NULL,
    duration_ms INTEGER,
    trace_id TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tool_invocations_project_created ON tool_invocations(project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tool_invocations_task_created ON tool_invocations(task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tool_invocations_tool_created ON tool_invocations(tool, created_at DESC);

CREATE TABLE IF NOT EXISTS workflow_runs (
    id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    workflow_version INTEGER NOT NULL,
    project_id TEXT NOT NULL,
    task_id TEXT,
    status TEXT NOT NULL,
    current_node_ids_json TEXT NOT NULL,
    started_by TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_workflow_runs_project ON workflow_runs(project_id, started_at DESC);

CREATE TABLE IF NOT EXISTS workflow_run_steps (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    status TEXT NOT NULL,
    input_json TEXT NOT NULL,
    output_json TEXT NOT NULL,
    error TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_workflow_run_steps_run ON workflow_run_steps(run_id, started_at ASC);

CREATE TABLE IF NOT EXISTS workflow_pending_actions (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    workflow_run_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    task_id TEXT,
    assignee TEXT NOT NULL,
    prompt TEXT NOT NULL,
    decisions_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    resolved_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_workflow_pending_actions_project ON workflow_pending_actions(project_id, resolved_at, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_pending_actions_run ON workflow_pending_actions(workflow_run_id);

CREATE TABLE IF NOT EXISTS automation_runs (
    id TEXT PRIMARY KEY,
    automation_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    workflow_id TEXT NOT NULL,
    workflow_run_id TEXT,
    repository_full_name TEXT NOT NULL,
    trigger_type TEXT NOT NULL,
    trigger_event_id TEXT,
    status TEXT NOT NULL,
    task_id TEXT,
    summary TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_automation_runs_project ON automation_runs(project_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_automation_runs_automation ON automation_runs(automation_id, started_at DESC);

CREATE TABLE IF NOT EXISTS self_improvement_proposal_review_queue (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    review_context TEXT,
    status TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_run_at TEXT NOT NULL,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(agent_id, session_id, reason)
);

CREATE INDEX IF NOT EXISTS idx_self_improvement_proposal_review_queue_due
ON self_improvement_proposal_review_queue(status, next_run_at);

CREATE TABLE IF NOT EXISTS autodream_session_reviews (
    agent_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    status TEXT NOT NULL,
    reason TEXT NOT NULL,
    session_updated_at TEXT NOT NULL,
    reviewed_at TEXT NOT NULL,
    last_error TEXT,
    PRIMARY KEY(agent_id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_autodream_session_reviews_status_reviewed
ON autodream_session_reviews(status, reviewed_at DESC);

CREATE TABLE IF NOT EXISTS project_event_facts (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    message_type TEXT NOT NULL,
    trace_id TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_project_event_facts_project_created ON project_event_facts(project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_project_event_facts_project_type_created ON project_event_facts(project_id, message_type, created_at DESC);

CREATE TABLE IF NOT EXISTS dashboard_projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    actors_json TEXT NOT NULL DEFAULT '[]',
    teams_json TEXT NOT NULL DEFAULT '[]',
    project_kind TEXT NOT NULL DEFAULT 'project',
    directory_paths_json TEXT NOT NULL DEFAULT '[]',
    automatic_task_pickup_enabled INTEGER NOT NULL DEFAULT 1,
    autopilot_settings_json TEXT NOT NULL DEFAULT '{}',
    is_favorite INTEGER NOT NULL DEFAULT 0,
    source_control_provider_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dashboard_project_channels (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    title TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(project_id, channel_id)
);

CREATE INDEX IF NOT EXISTS idx_dashboard_project_channels_project ON dashboard_project_channels(project_id);

CREATE TABLE IF NOT EXISTS dashboard_project_tasks (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    priority TEXT NOT NULL,
    status TEXT NOT NULL,
    actor_id TEXT,
    team_id TEXT,
    claimed_actor_id TEXT,
    claimed_agent_id TEXT,
    parent_task_id TEXT,
    created_by TEXT,
    depends_on_task_ids_json TEXT NOT NULL DEFAULT '[]',
    swarm_id TEXT,
    swarm_task_id TEXT,
    swarm_parent_task_id TEXT,
    swarm_dependency_ids_json TEXT NOT NULL DEFAULT '[]',
    swarm_depth INTEGER,
    swarm_actor_path_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    worktree_branch TEXT,
    source_control_provider_id TEXT,
    kind TEXT,
    loop_mode_override TEXT,
    origin_type TEXT,
    origin_channel_id TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0,
    selected_model TEXT,
    attachments_json TEXT NOT NULL DEFAULT '[]',
    external_metadata_json TEXT,
    tags_json TEXT NOT NULL DEFAULT '[]',
    execution_node_id TEXT,
    stage_assignments_json TEXT,
    active_stage TEXT,
    kanban_column_entered_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_dashboard_project_tasks_project ON dashboard_project_tasks(project_id);

CREATE TABLE IF NOT EXISTS channel_plugins (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    base_url TEXT NOT NULL,
    channel_ids_json TEXT NOT NULL DEFAULT '[]',
    config_json TEXT NOT NULL DEFAULT '{}',
    enabled INTEGER NOT NULL DEFAULT 1,
    delivery_mode TEXT NOT NULL DEFAULT 'http',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS agent_plugins (
    id TEXT PRIMARY KEY,
    record_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS agent_plugin_registries (
    id TEXT PRIMARY KEY,
    record_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS channel_access_users (
    id TEXT PRIMARY KEY,
    platform TEXT NOT NULL,
    platform_user_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(platform, platform_user_id)
);

CREATE INDEX IF NOT EXISTS idx_channel_access_users_platform ON channel_access_users(platform, status);

CREATE TABLE IF NOT EXISTS agent_proactive_state (
    agent_id TEXT PRIMARY KEY,
    payload TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS session_launch_state (
    agent_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (agent_id, session_id)
);

-- Usage attribution begins with collection; no historical reconstruction.
CREATE TABLE IF NOT EXISTS usage_collection (id INTEGER PRIMARY KEY CHECK(id = 1), started_at TEXT NOT NULL);
INSERT OR IGNORE INTO usage_collection VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
CREATE TABLE IF NOT EXISTS usage_requests (
    id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, session_id TEXT, agent_id TEXT,
    provider TEXT NOT NULL, model TEXT NOT NULL, created_at TEXT NOT NULL,
    prompt_tokens INTEGER, completion_tokens INTEGER, cached_tokens INTEGER,
    cache_creation_tokens INTEGER, reasoning_tokens INTEGER,
    failed INTEGER NOT NULL, complete INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_requests_channel_date ON usage_requests(channel_id, created_at);
CREATE INDEX IF NOT EXISTS idx_usage_requests_date ON usage_requests(created_at);
CREATE TABLE IF NOT EXISTS usage_calls (
    id TEXT NOT NULL, channel_id TEXT NOT NULL, request_id TEXT NOT NULL,
    session_id TEXT, agent_id TEXT, tool TEXT NOT NULL, server_id TEXT, skill_id TEXT,
    ok INTEGER, created_at TEXT NOT NULL, PRIMARY KEY(channel_id, id)
);
CREATE INDEX IF NOT EXISTS idx_usage_calls_request ON usage_calls(request_id);
CREATE TABLE IF NOT EXISTS usage_components (
    id TEXT PRIMARY KEY, request_id TEXT NOT NULL, channel_id TEXT NOT NULL,
    tool_call_id TEXT, tool TEXT, server_id TEXT, skill_id TEXT, kind TEXT NOT NULL,
    tokens INTEGER, method TEXT NOT NULL, encoding TEXT, repeated INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_components_request ON usage_components(request_id);
CREATE INDEX IF NOT EXISTS idx_usage_components_replay ON usage_components(channel_id, tool_call_id, kind);
