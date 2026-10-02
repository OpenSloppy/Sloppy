import React, { useCallback, useEffect, useRef, useState } from "react";
import { requestJson, formatHttpError } from "../../../shared/api/httpClient";

type Environment = "test" | "production";
interface Account { id: string; name: string; email: string }
interface Binding { id: string; name: string; ownerID: string; status: string; hostCertificateFingerprint: string }
interface Status { environment: Environment; consoleURL: string; relayURL: string; signedIn: boolean; account?: Account; binding?: Binding; boundEnvironment?: Environment }
interface Login { id: string; userCode: string; verificationURL: string; expiresAt: number; interval: number }
interface Review { environment: Environment; account: Account; binding: Binding; proposalID: string; expiresAt: number }

async function call<T>(path: string, body?: unknown): Promise<T> {
  const response = await requestJson<T>({ path: `/v1/console/account${path}`, method: body === undefined ? "GET" : "POST", body });
  if (!response.ok || !response.data) {
    const code = (response.data as { error?: string } | null)?.error;
    const messages: Record<string, string> = {
      local_owner_required: "Open this Dashboard locally and sign in as its administrator to connect Console.",
      console_sign_in_required: "Sign in to Console to continue.",
      console_mfa_or_access_required: "Verify your Console account with MFA, then retry the binding.",
      console_login_expired: "The sign-in code expired. Start sign-in again.",
      console_environment_or_owner_conflict: "This session or instance belongs to a different account or environment.",
      console_unavailable: "Console is unavailable. Check the connection and selected environment.",
    };
    throw new Error(code && messages[code] ? messages[code] : formatHttpError(response.status, response.data));
  }
  return response.data;
}

export function ConsoleAccountCard() {
  const [environment, setEnvironment] = useState<Environment>(__DASHBOARD_DEV__ ? "test" : "production");
  const [status, setStatus] = useState<Status | null>(null);
  const [login, setLogin] = useState<Login | null>(null);
  const [review, setReview] = useState<Review | null>(null);
  const [confirmUnbind, setConfirmUnbind] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const generation = useRef(0);

  const load = useCallback(async () => {
    const current = generation.current;
    const next = await call<Status>(`?environment=${environment}`);
    if (current !== generation.current) return;
    setStatus(next);
    if (next.binding && next.boundEnvironment && next.boundEnvironment !== environment) setEnvironment(next.boundEnvironment);
  }, [environment]);

  useEffect(() => {
    generation.current += 1;
    setStatus(null); setReview(null); setMessage("");
    void load().catch(error => setMessage(error.message));
    return () => { generation.current += 1; };
  }, [load]);

  useEffect(() => {
    if (!login) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      if (cancelled) return;
      if (Date.now() >= login.expiresAt) { setLogin(null); setMessage("The sign-in code expired. Start sign-in again."); return; }
      try {
        const result = await call<{ signedIn: boolean }>("/poll", { id: login.id, environment });
        if (cancelled) return;
        if (result.signedIn) { setLogin(null); setMessage("Signed in. Review and connect this instance next."); await load(); return; }
      } catch (error) {
        if (!cancelled) { setLogin(null); setMessage((error as Error).message); }
        return;
      }
      timer = setTimeout(poll, login.interval * 1000);
    };
    timer = setTimeout(poll, login.interval * 1000);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [login, environment, load]);

  const action = async (perform: () => Promise<void>) => {
    if (busy) return;
    setBusy(true); setMessage("");
    try { await perform(); } catch (error) { setMessage((error as Error).message); }
    finally { setBusy(false); }
  };
  const start = () => action(async () => {
    const next = await call<Login>("/login", { environment });
    setLogin(next);
  });
  const bound = status?.binding?.status === "active";
  return <section className="auth-panel console-account-panel" aria-labelledby="console-account-title">
    <div className="auth-section-heading">
      <span className="auth-section-icon"><span className="material-symbols-rounded" aria-hidden="true">cloud_done</span></span>
      <span className="auth-section-copy">
        <span className="auth-heading-line"><h4 id="console-account-title">Sloppy Console</h4>
          <span className={`auth-status-badge ${bound ? "is-active" : ""}`}>{bound ? "Instance connected" : status?.signedIn ? "Account connected" : "Optional"}</span>
        </span>
        <span>Connect your account for cloud Relay and automatic mesh. Local work and pairing remain available.</span>
      </span>
    </div>
    <div className="console-account-body">
      {__DASHBOARD_DEV__ && <label className="console-environment">Console environment
        <select aria-label="Console environment" value={environment} disabled={busy || Boolean(login) || Boolean(review) || Boolean(status?.binding)}
          onChange={event => setEnvironment(event.target.value as Environment)}>
          <option value="test">Test · pilot</option><option value="production">Production</option>
        </select>
      </label>}
      {__DASHBOARD_DEV__ && environment === "production" && !bound && <p className="placeholder-text">Production customer sign-in is currently closed. Use Test for the pilot.</p>}
      {status?.account && <div className="console-account-identity"><strong>{status.account.name}</strong><span>{status.account.email}</span></div>}
      {bound && status?.binding && <div className="console-binding-details"><strong>{status.binding.name}</strong><code>{status.binding.id}</code><span>{status.boundEnvironment === "test" ? "Test" : "Production"} Console and Relay</span></div>}
      {login ? <div className="console-login-code" role="status">
        <p>Open the sign-in page in your regular browser and enter this one-time code:</p>
        <strong>{login.userCode}</strong>
        <a className="auth-button is-primary" href={login.verificationURL} target="_blank" rel="noopener noreferrer">Open Console sign-in</a>
        <p className="placeholder-text">Complete Google/Apple sign-in and MFA. This page will update automatically.</p>
        <button className="auth-button" disabled={busy} onClick={() => void action(async () => { await call("/cancel", {id:login.id}); setLogin(null); })}>Cancel sign-in</button>
      </div> : <div className="console-account-actions">
        {!status?.signedIn && <button className="auth-button is-primary" disabled={busy || !status} onClick={() => void start()}>Connect Sloppy Console</button>}
        {status?.signedIn && !bound && <button className="auth-button is-primary" disabled={busy} onClick={() => void action(async () => { setReview(await call<Review>("/binding", {environment})); })}>Connect this instance</button>}
        {status?.signedIn && <button className="auth-button" disabled={busy} onClick={() => void start()}>Verify with MFA</button>}
        {status?.signedIn && <button className="auth-button" disabled={busy || Boolean(review)} onClick={() => void action(async () => { await call("/logout", {environment}); setMessage("Signed out of Console. The instance binding remains active."); await load(); })}>Sign out of Console</button>}
        {bound && <button className="auth-button" disabled={busy || !status?.signedIn} onClick={() => setConfirmUnbind(true)}>Unbind this instance</button>}
        <button className="auth-button" disabled={busy} onClick={() => void action(load)}>Refresh</button>
      </div>}
      {confirmUnbind && <div className="console-binding-review" role="region" aria-label="Confirm unbinding">
        <h4>Unbind this instance?</h4>
        <p>Disconnect cloud Relay and revoke cloud access to this instance. Local data, work and pairing are preserved.</p>
        <div className="console-account-actions">
          <button className="auth-button" disabled={busy} onClick={() => void action(async () => { await call("/binding/unbind", {environment, confirm:true}); setConfirmUnbind(false); setMessage("Instance disconnected from Console."); await load(); })}>Confirm unbind</button>
          <button className="auth-button" disabled={busy} onClick={() => setConfirmUnbind(false)}>Cancel</button>
        </div>
      </div>}
      {review && <div className="console-binding-review" role="region" aria-label="Confirm instance binding">
        <h4>Confirm instance binding</h4>
        <p>Connect <strong>{review.binding.name}</strong> to <strong>{review.account.name} ({review.account.email})</strong> in {review.environment === "test" ? "Test" : "Production"} Console?</p>
        <span>Instance ID</span><code>{review.binding.id}</code>
        <span>Host certificate SHA-256</span><code>{review.binding.hostCertificateFingerprint}</code>
        <p className="placeholder-text">This confirms ownership and enables cloud discovery. Additional devices and access permissions still require approval by trusted Sloppy.</p>
        <div className="console-account-actions">
          <button className="auth-button is-primary" disabled={busy || Date.now() >= review.expiresAt} onClick={() => void action(async () => { await call("/binding/confirm", {environment:review.environment, proposalID:review.proposalID, confirm:true}); setReview(null); setMessage("Instance connected to Sloppy Console."); await load(); })}>Confirm and connect</button>
          <button className="auth-button" disabled={busy} onClick={() => setReview(null)}>Cancel</button>
        </div>
      </div>}
      {message && <p className="placeholder-text console-account-message" role="status">{message}</p>}
    </div>
  </section>;
}
