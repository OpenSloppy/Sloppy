import React, { useEffect, useMemo, useState } from "react";
import { fetchAgent, fetchAgentTasks, fetchAgentSessions, fetchAgentTokenUsage } from "../../../api";
import { AgentPetCard } from "./AgentPetCard";

export function AgentOverviewTab({ agent, navigateToAgent }: any) {
    const [agentSnapshot, setAgentSnapshot] = useState<any>(agent);
    const [tasks, setTasks] = useState<any[]>([]);
    const [sessions, setSessions] = useState<any[]>([]);
    const [tokenUsage, setTokenUsage] = useState<any>(null);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
        setAgentSnapshot(agent);
    }, [agent]);

    useEffect(() => {
        let cancelled = false;
        async function loadData() {
            setIsLoading(true);
            try {
                const [agentRes, tasksRes, sessionsRes, tokenRes] = await Promise.all([
                    fetchAgent(agent.id),
                    fetchAgentTasks(agent.id),
                    fetchAgentSessions(agent.id),
                    fetchAgentTokenUsage(agent.id)
                ]);
                if (!cancelled) {
                    if (agentRes) setAgentSnapshot(agentRes);
                    if (Array.isArray(tasksRes)) setTasks(tasksRes);
                    if (Array.isArray(sessionsRes)) setSessions(sessionsRes);
                    if (tokenRes) setTokenUsage(tokenRes);
                }
            } catch (err) {
                console.error("Failed to fetch overview data", err);
            } finally {
                if (!cancelled) setIsLoading(false);
            }
        }
        loadData();
        return () => { cancelled = true; };
    }, [agent.id]);

    const recentTasks = tasks.slice(0, 8);
    const latestSession = sessions.length > 0 ? sessions[sessions.length - 1] : null;
    let lastRunTime = "N/A";
    if (latestSession && latestSession.createdAt) {
        lastRunTime = new Date(latestSession.createdAt).toLocaleString(undefined, {
            month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'
        });
    }

    const runActivity = useMemo(() => {
        const data = [];
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        for (let i = 13; i >= 0; i--) {
            const d = new Date(today);
            d.setDate(today.getDate() - i);
            let count = 0;
            sessions.forEach(s => {
                if (!s.createdAt) return;
                const sd = new Date(s.createdAt);
                if (sd.getDate() === d.getDate() && sd.getMonth() === d.getMonth() && sd.getFullYear() === d.getFullYear()) count++;
            });
            data.push({ dateStr: `${d.getMonth() + 1}/${d.getDate()}`, value: count });
        }
        const max = Math.max(...data.map(d => d.value), 1);
        return data.map(d => ({ ...d, percent: (d.value / max) * 100 }));
    }, [sessions]);

    const priorityActivity = useMemo(() => {
        const data = [];
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        for (let i = 13; i >= 0; i--) {
            const d = new Date(today);
            d.setDate(today.getDate() - i);
            let critical = 0, high = 0, medium = 0, low = 0;
            tasks.forEach(t => {
                const task = t.task || {};
                if (!task.createdAt) return;
                const td = new Date(task.createdAt);
                if (td.getDate() === d.getDate() && td.getMonth() === d.getMonth() && td.getFullYear() === d.getFullYear()) {
                    if (task.priority === 'critical') critical++;
                    else if (task.priority === 'high') high++;
                    else if (task.priority === 'medium') medium++;
                    else low++;
                }
            });
            data.push({ dateStr: `${d.getMonth() + 1}/${d.getDate()}`, total: critical + high + medium + low, critical, high, medium, low });
        }
        const max = Math.max(...data.map(d => d.total), 1);
        return data.map(d => ({
            ...d,
            criticalP: (d.critical / max) * 100,
            highP: (d.high / max) * 100,
            mediumP: (d.medium / max) * 100,
            lowP: (d.low / max) * 100,
        }));
    }, [tasks]);

    const statusActivity = useMemo(() => {
        const data = [];
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        for (let i = 13; i >= 0; i--) {
            const d = new Date(today);
            d.setDate(today.getDate() - i);
            let todo = 0, inprogress = 0, done = 0;
            tasks.forEach(t => {
                const task = t.task || {};
                if (!task.createdAt) return;
                const td = new Date(task.createdAt);
                if (td.getDate() === d.getDate() && td.getMonth() === d.getMonth() && td.getFullYear() === d.getFullYear()) {
                    const status = String(task.status).toLowerCase();
                    if (status === 'done') done++;
                    else if (status === 'in_progress' || status === 'inprogress') inprogress++;
                    else todo++;
                }
            });
            data.push({ dateStr: `${d.getMonth() + 1}/${d.getDate()}`, total: todo + inprogress + done, todo, inprogress, done });
        }
        const max = Math.max(...data.map(d => d.total), 1);
        return data.map(d => ({
            ...d,
            todoP: (d.todo / max) * 100,
            progP: (d.inprogress / max) * 100,
            doneP: (d.done / max) * 100,
        }));
    }, [tasks]);

    return (
        <div className="agent-dashboard">
            <div className="agent-top-grid">
                <div className="agent-top-left">
                    <AgentPetCard pet={agentSnapshot?.pet} agentId={agent.id} />

                    <section className="dashboard-section">
                        <div className="dashboard-section-header">
                            <h3>Latest Run</h3>
                            <button className="text-button" onClick={() => navigateToAgent(agent.id, 'memories')}>View history &rarr;</button>
                        </div>
                        <div className="latest-run-card">
                            {latestSession ? (
                                <>
                                    <div className="latest-run-status">
                                        <span className={`material-symbols-rounded text-${latestSession.failureReason ? 'critical' : 'done'}`}>
                                            {latestSession.failureReason ? 'error' : 'check_circle'}
                                        </span>
                                        <span className="run-id">{latestSession.id.split('-')[0]}</span>
                                        <span className="badge badge-assignment">{latestSession.kind || 'Session'}</span>
                                    </div>
                                    <span className="run-time">{lastRunTime}</span>
                                </>
                            ) : (
                                <span className="text-muted">No sessions yet.</span>
                            )}
                        </div>
                    </section>
                </div>

                <div className="agent-top-right">
                    <section className="dashboard-section">
                        <div className="dashboard-section-header">
                            <h3>Costs</h3>
                            <button className="text-button" onClick={() => navigateToAgent(agent.id, 'memories')}>View sessions &rarr;</button>
                        </div>
                        <div className="costs-card">
                            <div className="cost-metric">
                                <span className="cost-label">Total Prompt tokens</span>
                                <span className="cost-value">{tokenUsage?.inputTokens?.toLocaleString() || '0'}</span>
                            </div>
                            <div className="cost-metric">
                                <span className="cost-label">Total Completion tokens</span>
                                <span className="cost-value">{tokenUsage?.outputTokens?.toLocaleString() || '0'}</span>
                            </div>
                            <div className="cost-metric">
                                <span className="cost-label">Total tokens</span>
                                <span className="cost-value">
                                    {((tokenUsage?.inputTokens || 0) + (tokenUsage?.outputTokens || 0)).toLocaleString()}
                                </span>
                            </div>
                            <div className="cost-metric">
                                <span className="cost-label">Cost estimate (Last 30 days)</span>
                                <span className="cost-value">
                                    {tokenUsage?.totalCostUSD !== undefined && tokenUsage?.totalCostUSD !== null && tokenUsage.totalCostUSD > 0
                                        ? `$${tokenUsage.totalCostUSD.toFixed(3)}`
                                        : '—'}
                                </span>
                            </div>
                        </div>
                    </section>

                    <section className="dashboard-section">
                        <div className="dashboard-section-header">
                            <h3>Recent Issues</h3>
                            <button className="text-button" onClick={() => navigateToAgent(agent.id, 'tasks')}>See All &rarr;</button>
                        </div>
                        <div className="recent-issues-list">
                            {isLoading ? (
                                <div className="recent-issue-item text-muted">Loading tasks...</div>
                            ) : recentTasks.length === 0 ? (
                                <div className="recent-issue-item text-muted">No recent tasks.</div>
                            ) : (
                                recentTasks.map((taskItem, i) => {
                                    const task = taskItem.task || {};
                                    const id = task.id || `COR-${i + 1}`;
                                    const title = task.title || "Task";
                                    const status = String(task.status || "todo").toLowerCase();
                                    return (
                                        <div key={id} className="recent-issue-item">
                                            <span className="issue-id">{id}</span>
                                            <span className="issue-title">{title}</span>
                                            <span className={`badge badge-outline`}>{status}</span>
                                        </div>
                                    );
                                })
                            )}
                        </div>
                    </section>
                </div>
            </div>

            <section className="dashboard-charts-grid">
                <div className="chart-card">
                    <div className="chart-header">
                        <h4>Run Activity</h4>
                        <span className="chart-period">Last 14 days</span>
                    </div>
                    <div className="chart-body">
                        <div className="chart-bars">
                            {runActivity.map((d, i) => (
                                <div key={i} className="chart-bar-wrap" title={`Runs: ${d.value}`}>
                                    <div className="chart-bar bg-gray" style={{ height: `${d.percent}%` }} />
                                </div>
                            ))}
                        </div>
                        <div className="chart-x-axis">
                            <span>{runActivity[0]?.dateStr}</span>
                            <span>{runActivity[Math.floor(runActivity.length / 2)]?.dateStr}</span>
                            <span>{runActivity[runActivity.length - 1]?.dateStr}</span>
                        </div>
                    </div>
                </div>

                <div className="chart-card">
                    <div className="chart-header">
                        <h4>Issues by Priority</h4>
                        <span className="chart-period">Last 14 days</span>
                    </div>
                    <div className="chart-body">
                        <div className="chart-bars">
                            {priorityActivity.map((d, i) => (
                                <div key={i} className="chart-bar-wrap" style={{ display: 'flex', flexDirection: 'column-reverse' }} title={`Crit: ${d.critical}, High: ${d.high}, Med: ${d.medium}, Low: ${d.low}`}>
                                    {d.criticalP > 0 && <div className="bg-critical" style={{ minHeight: `${d.criticalP}%`, width: '100%', borderRadius: '4px' }} />}
                                    {d.highP > 0 && <div className="bg-high" style={{ minHeight: `${d.highP}%`, width: '100%', borderRadius: '4px' }} />}
                                    {d.mediumP > 0 && <div className="bg-medium" style={{ minHeight: `${d.mediumP}%`, width: '100%', borderRadius: '4px' }} />}
                                    {d.lowP > 0 && <div className="bg-low" style={{ minHeight: `${d.lowP}%`, width: '100%', borderRadius: '4px' }} />}
                                </div>
                            ))}
                        </div>
                        <div className="chart-x-axis">
                            <span>{priorityActivity[0]?.dateStr}</span>
                            <span>{priorityActivity[Math.floor(priorityActivity.length / 2)]?.dateStr}</span>
                            <span>{priorityActivity[priorityActivity.length - 1]?.dateStr}</span>
                        </div>
                        <div className="chart-legend">
                            <span><span className="legend-dot bg-critical"></span>Critical</span>
                            <span><span className="legend-dot bg-high"></span>High</span>
                            <span><span className="legend-dot bg-medium"></span>Medium</span>
                            <span><span className="legend-dot bg-low"></span>Low</span>
                        </div>
                    </div>
                </div>

                <div className="chart-card">
                    <div className="chart-header">
                        <h4>Issues by Status</h4>
                        <span className="chart-period">Last 14 days</span>
                    </div>
                    <div className="chart-body">
                        <div className="chart-bars">
                            {statusActivity.map((d, i) => (
                                <div key={i} className="chart-bar-wrap" style={{ display: 'flex', flexDirection: 'column-reverse' }} title={`To Do: ${d.todo}, In Prog: ${d.inprogress}, Done: ${d.done}`}>
                                    {d.todoP > 0 && <div className="bg-gray" style={{ minHeight: `${d.todoP}%`, width: '100%', borderRadius: '4px' }} />}
                                    {d.progP > 0 && <div className="bg-blue" style={{ minHeight: `${d.progP}%`, width: '100%', borderRadius: '4px' }} />}
                                    {d.doneP > 0 && <div className="bg-done" style={{ minHeight: `${d.doneP}%`, width: '100%', borderRadius: '4px' }} />}
                                </div>
                            ))}
                        </div>
                        <div className="chart-x-axis">
                            <span>{statusActivity[0]?.dateStr}</span>
                            <span>{statusActivity[Math.floor(statusActivity.length / 2)]?.dateStr}</span>
                            <span>{statusActivity[statusActivity.length - 1]?.dateStr}</span>
                        </div>
                        <div className="chart-legend">
                            <span><span className="legend-dot bg-gray"></span>To Do</span>
                            <span><span className="legend-dot bg-blue"></span>In Progress</span>
                            <span><span className="legend-dot bg-done"></span>Done</span>
                        </div>
                    </div>
                </div>

                <div className="chart-card">
                    <div className="chart-header">
                        <h4>Success Rate</h4>
                        <span className="chart-period">Last 14 days</span>
                    </div>
                    <div className="chart-body">
                        <div className="chart-bars">
                            {statusActivity.map((d, i) => {
                                const rate = d.total > 0 ? (d.done / d.total) * 100 : 0;
                                return (
                                    <div key={i} className="chart-bar-wrap" title={`Success: ${rate.toFixed(0)}%`}>
                                        <div className="chart-bar bg-green" style={{ height: `${rate}%` }} />
                                    </div>
                                );
                            })}
                        </div>
                        <div className="chart-x-axis">
                            <span>{statusActivity[0]?.dateStr}</span>
                            <span>{statusActivity[Math.floor(statusActivity.length / 2)]?.dateStr}</span>
                            <span>{statusActivity[statusActivity.length - 1]?.dateStr}</span>
                        </div>
                    </div>
                </div>
            </section>

            <section className="dashboard-section mt-4 configuration-section">
                <div className="dashboard-section-header">
                    <h3>Configuration</h3>
                    <button className="text-button flex-center gap-2" onClick={() => navigateToAgent(agent.id, 'config')}>
                        <span className="material-symbols-rounded text-sm">settings</span> Manage &rarr;
                    </button>
                </div>
            </section>
        </div>
    );
}
