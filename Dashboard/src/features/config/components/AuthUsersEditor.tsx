import React, { useCallback, useEffect, useState } from "react";
import { isDashboardAuthTokenPersisted, setDashboardAuthToken } from "../../../shared/api/dashboardAuth";
import { requestJson } from "../../../shared/api/httpClient";
import { ConsoleAccountCard } from "./ConsoleAccountCard";
import "./consoleAccount.css";

function AuthIcon({ name }: { name: string }) {
  return <span className="material-symbols-rounded auth-icon" aria-hidden="true">{name}</span>;
}

export function AuthUsersEditor() {
  const [identityAuthChallenge, setIdentityAuthChallenge] = useState<Record<string, any> | null>(null);
  const [identityAuthStatus, setIdentityAuthStatus] = useState("");
  const [currentIdentityUser, setCurrentIdentityUser] = useState<Record<string, any> | null>(null);
  const [identityUsers, setIdentityUsers] = useState<Record<string, any>[]>([]);
  const [identityUsersStatus, setIdentityUsersStatus] = useState("");
  const [inviteRole, setInviteRole] = useState("user");
  const [inviteToken, setInviteToken] = useState("");
  const [inviteStatus, setInviteStatus] = useState("");
  const [bootstrapName, setBootstrapName] = useState("Admin");
  const [bootstrapLogin, setBootstrapLogin] = useState("admin");
  const [bootstrapPassword, setBootstrapPassword] = useState("");
  const [recoveryCodes, setRecoveryCodes] = useState<string[]>([]);
  const [recoveryStatus, setRecoveryStatus] = useState("");
  const [passwordResetToken, setPasswordResetToken] = useState("");
  const [passwordResetStatus, setPasswordResetStatus] = useState("");
  const [passwordChangeUser, setPasswordChangeUser] = useState<{ login: string; name: string } | null>(null);
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [passwordChangeStatus, setPasswordChangeStatus] = useState("");
  const [passwordChangeWorking, setPasswordChangeWorking] = useState(false);
  const [applicationTokens, setApplicationTokens] = useState<Record<string, any>[]>([]);
  const [applicationTokenName, setApplicationTokenName] = useState("Sloppy Safari");
  const [createdApplicationToken, setCreatedApplicationToken] = useState("");
  const [applicationTokenStatus, setApplicationTokenStatus] = useState("");

  const loadAuthChallenge = useCallback(async () => {
    const response = await requestJson<Record<string, any>>({ path: "/v1/auth/challenge" });
    if (response.ok) {
      setIdentityAuthChallenge(response.data);
      return response.data;
    }
    return null;
  }, []);

  const loadIdentityUsers = useCallback(async () => {
    setIdentityUsersStatus("Loading users...");
    const response = await requestJson<Record<string, any>[]>({ path: "/v1/auth/users" });
    if (!response.ok || !response.data) {
      setIdentityUsers([]);
      setIdentityUsersStatus("Login as Admin to manage accounts.");
      return;
    }
    setIdentityUsers(response.data);
    setIdentityUsersStatus("");
  }, []);

  const loadCurrentIdentityUser = useCallback(async () => {
    const response = await requestJson<Record<string, any>>({ path: "/v1/auth/me" });
    setCurrentIdentityUser(response.ok && response.data ? response.data : null);
  }, []);

  const loadApplicationTokens = useCallback(async () => {
    const response = await requestJson<Record<string, any>[]>({ path: "/v1/auth/application-tokens" });
    if (!response.ok || !Array.isArray(response.data)) {
      setApplicationTokens([]);
      setApplicationTokenStatus("Unable to load application tokens.");
      return;
    }
    setApplicationTokens(response.data);
    setApplicationTokenStatus("");
  }, []);

  useEffect(() => {
    let cancelled = false;
    loadAuthChallenge().then((challenge) => {
      if (cancelled) return;
      if (challenge?.mode === "login_password" && !Boolean(challenge?.bootstrapRequired)) {
        void loadCurrentIdentityUser();
        void loadIdentityUsers();
        void loadApplicationTokens();
      }
    });
    return () => {
      cancelled = true;
    };
  }, [loadApplicationTokens, loadAuthChallenge, loadCurrentIdentityUser, loadIdentityUsers]);

  useEffect(() => {
    if (!passwordChangeUser) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !passwordChangeWorking) {
        setPasswordChangeUser(null);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [passwordChangeUser, passwordChangeWorking]);

  const enableLoginPasswordAuth = useCallback(async () => {
    const confirmed = window.confirm(
      "Switch Sloppy to login/password authentication? This action cannot be reverted to token auth."
    );
    if (!confirmed) return;
    setIdentityAuthStatus("Enabling login/password auth...");
    const response = await requestJson<Record<string, any>, Record<string, any>>({
      path: "/v1/auth/mode",
      method: "POST",
      body: {
        mode: "login_password",
        confirmIrreversible: true
      }
    });
    if (!response.ok || !response.data) {
      setIdentityAuthStatus("Failed to enable login/password auth.");
      return;
    }
    setIdentityAuthChallenge(response.data);
    setIdentityAuthStatus("Login/password auth enabled. Create the first Admin account next.");
  }, []);

  const bootstrapFirstAdmin = useCallback(async () => {
    if (!bootstrapLogin.trim() || !bootstrapPassword) {
      setIdentityAuthStatus("Enter admin login and password.");
      return;
    }
    setIdentityAuthStatus("Creating the first Admin account...");
    const response = await requestJson<Record<string, any>, Record<string, any>>({
      path: "/v1/auth/bootstrap",
      method: "POST",
      body: {
        login: bootstrapLogin.trim(),
        name: bootstrapName.trim() || bootstrapLogin.trim(),
        password: bootstrapPassword
      }
    });
    const accessToken = typeof response.data?.accessToken === "string" ? response.data.accessToken.trim() : "";
    if (!response.ok || !accessToken) {
      setIdentityAuthStatus("Failed to create the first Admin account.");
      return;
    }
    setDashboardAuthToken(accessToken, { persist: true });
    setBootstrapPassword("");
    setIdentityAuthStatus("Admin account created and session saved in this browser.");
    await loadAuthChallenge();
    await loadIdentityUsers();
  }, [bootstrapLogin, bootstrapName, bootstrapPassword, loadAuthChallenge, loadIdentityUsers]);

  const createInvite = useCallback(async () => {
    setInviteStatus("Creating invite...");
    const response = await requestJson<Record<string, any>, Record<string, any>>({
      path: "/v1/auth/invites",
      method: "POST",
      body: {
        role: inviteRole,
        ttlSeconds: 604800
      }
    });
    const token = typeof response.data?.token === "string" ? response.data.token : "";
    if (!response.ok || !token) {
      setInviteStatus("Failed to create invite.");
      return;
    }
    setInviteToken(token);
    setInviteStatus("Invite created. Copy and share this token securely.");
  }, [inviteRole]);

  const updateIdentityUser = useCallback(async (login: string, patch: Record<string, any>) => {
    setIdentityUsersStatus("Updating user...");
    const response = await requestJson<Record<string, any>, Record<string, any>>({
      path: `/v1/auth/users/${encodeURIComponent(login)}`,
      method: "PATCH",
      body: patch
    });
    if (!response.ok) {
      setIdentityUsersStatus("Failed to update user. The last active Admin cannot be disabled or demoted.");
      return;
    }
    await loadIdentityUsers();
  }, [loadIdentityUsers]);

  const generateRecoveryCodes = useCallback(async () => {
    setRecoveryStatus("Generating recovery codes...");
    const response = await requestJson<Record<string, any>>({
      path: "/v1/auth/recovery-codes",
      method: "POST"
    });
    const codes = Array.isArray(response.data?.codes) ? response.data.codes.map((code) => String(code)) : [];
    if (!response.ok || codes.length === 0) {
      setRecoveryStatus("Failed to generate recovery codes.");
      return;
    }
    setRecoveryCodes(codes);
    setRecoveryStatus("Recovery codes generated. Store them now; they are one-time codes.");
  }, []);

  const createPasswordResetToken = useCallback(async (login: string) => {
    setPasswordResetStatus(`Creating a password reset token for @${login}...`);
    const response = await requestJson<Record<string, any>>({
      path: `/v1/auth/users/${encodeURIComponent(login)}/password-reset-token`,
      method: "POST"
    });
    const token = typeof response.data?.resetToken === "string" ? response.data.resetToken : "";
    if (!response.ok || !token) {
      setPasswordResetStatus("Failed to create password reset token.");
      return;
    }
    setPasswordResetToken(token);
    setPasswordResetStatus(`Password reset token created for @${login}.`);
  }, []);

  const openPasswordChangeDialog = useCallback((login: string, name: string) => {
    setPasswordChangeUser({ login, name });
    setCurrentPassword("");
    setNewPassword("");
    setPasswordChangeStatus("");
  }, []);

  const changePassword = useCallback(async () => {
    if (!passwordChangeUser || !currentPassword || !newPassword) {
      setPasswordChangeStatus("Enter both your current and new password.");
      return;
    }
    setPasswordChangeWorking(true);
    setPasswordChangeStatus("Changing password...");
    const response = await requestJson<Record<string, any>, Record<string, any>>({
      path: "/v1/auth/password",
      method: "POST",
      body: {
        currentPassword,
        newPassword
      }
    });
    const accessToken = typeof response.data?.accessToken === "string" ? response.data.accessToken.trim() : "";
    if (!response.ok || !accessToken) {
      setPasswordChangeWorking(false);
      setPasswordChangeStatus("Password change failed. Check your current password and try again.");
      return;
    }
    setDashboardAuthToken(accessToken, { persist: isDashboardAuthTokenPersisted() });
    setPasswordChangeWorking(false);
    setPasswordChangeUser(null);
    setCurrentPassword("");
    setNewPassword("");
    setIdentityUsersStatus(`Password changed for @${passwordChangeUser.login}.`);
  }, [currentPassword, newPassword, passwordChangeUser]);

  const createApplicationToken = useCallback(async () => {
    const name = applicationTokenName.trim();
    if (!name) {
      setApplicationTokenStatus("Enter a token name.");
      return;
    }
    setApplicationTokenStatus("Creating application token...");
    setCreatedApplicationToken("");
    const response = await requestJson<Record<string, any>, Record<string, any>>({
      path: "/v1/auth/application-tokens",
      method: "POST",
      body: {
        name,
        expiresInSeconds: 31_536_000
      }
    });
    const token = typeof response.data?.token === "string" ? response.data.token.trim() : "";
    if (!response.ok || !token) {
      setApplicationTokenStatus("Failed to create application token.");
      return;
    }
    setCreatedApplicationToken(token);
    await loadApplicationTokens();
    setApplicationTokenStatus("Token created. Copy it now; it will not be shown again.");
  }, [applicationTokenName, loadApplicationTokens]);

  const revokeApplicationToken = useCallback(async (id: string, name: string) => {
    if (!window.confirm(`Revoke application token “${name}”?`)) return;
    setApplicationTokenStatus("Revoking application token...");
    const response = await requestJson({
      path: `/v1/auth/application-tokens/${encodeURIComponent(id)}`,
      method: "DELETE"
    });
    if (!response.ok) {
      setApplicationTokenStatus("Failed to revoke application token.");
      return;
    }
    setCreatedApplicationToken("");
    await loadApplicationTokens();
  }, [loadApplicationTokens]);

  const copyCreatedApplicationToken = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(createdApplicationToken);
      setApplicationTokenStatus("Token copied. It will not be shown again after you leave this page.");
    } catch {
      setApplicationTokenStatus("Unable to copy automatically. Select the token and copy it manually.");
    }
  }, [createdApplicationToken]);

  const loginPasswordEnabled = identityAuthChallenge?.mode === "login_password";

  return (
    <section className="entry-editor-card auth-users-editor">
      <header className="auth-users-header">
        <span className="auth-users-eyebrow">Access control</span>
        <h3>Users &amp; Auth</h3>
        <p>Control who can sign in, what they can manage, and which apps can access this Sloppy instance.</p>
      </header>

      <ConsoleAccountCard />

      <section className="auth-panel auth-mode-panel" aria-labelledby="auth-mode-title">
        <div className="auth-section-heading">
          <span className="auth-section-icon"><AuthIcon name="shield_lock" /></span>
          <span className="auth-section-copy">
            <span className="auth-heading-line">
              <h4 id="auth-mode-title">Login method</h4>
              <span className={`auth-status-badge ${loginPasswordEnabled ? "is-active" : ""}`}>
                {loginPasswordEnabled ? "Password enabled" : "Access token"}
              </span>
            </span>
            <span>
              {loginPasswordEnabled
                ? "People sign in with their Sloppy account."
                : "This instance currently uses a shared access token."}
            </span>
          </span>
        </div>
        {!loginPasswordEnabled ? (
          <div className="auth-mode-action">
            <span><AuthIcon name="warning" /> This change is permanent.</span>
            <button type="button" className="auth-button is-primary" onClick={enableLoginPasswordAuth}>
              Enable login &amp; password
            </button>
          </div>
        ) : null}
        {identityAuthStatus ? <p className="auth-inline-status" role="status">{identityAuthStatus}</p> : null}
      </section>

      {loginPasswordEnabled && identityAuthChallenge?.bootstrapRequired ? (
        <section className="auth-panel" aria-labelledby="auth-bootstrap-title">
          <div className="auth-section-heading">
            <span className="auth-section-icon"><AuthIcon name="person_add" /></span>
            <span className="auth-section-copy">
              <h4 id="auth-bootstrap-title">Create the first admin</h4>
              <span>This account receives full access to users, settings, and tokens.</span>
            </span>
          </div>
          <div className="auth-form-grid">
            <label>
              Display name
              <input value={bootstrapName} onChange={(event) => setBootstrapName(event.target.value)} />
            </label>
            <label>
              Login
              <input
                value={bootstrapLogin}
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
                onChange={(event) => setBootstrapLogin(event.target.value)}
              />
            </label>
            <label>
              Password
              <input
                type="password"
                value={bootstrapPassword}
                onChange={(event) => setBootstrapPassword(event.target.value)}
              />
            </label>
            <button type="button" className="auth-button is-primary" onClick={() => void bootstrapFirstAdmin()}>
              Create admin
            </button>
          </div>
        </section>
      ) : null}

      {loginPasswordEnabled && !identityAuthChallenge?.bootstrapRequired ? (
        <>
          <section className="auth-panel" aria-labelledby="auth-accounts-title">
            <div className="auth-panel-header">
              <div className="auth-section-heading">
                <span className="auth-section-icon"><AuthIcon name="group" /></span>
                <span className="auth-section-copy">
                  <span className="auth-heading-line">
                    <h4 id="auth-accounts-title">Accounts</h4>
                    <span className="auth-count-badge">{identityUsers.length}</span>
                  </span>
                  <span>Assign roles, suspend access, or issue a password reset.</span>
                </span>
              </div>
              <button
                type="button"
                className="auth-icon-button"
                aria-label="Refresh accounts"
                title="Refresh accounts"
                onClick={() => void loadIdentityUsers()}
              >
                <AuthIcon name="refresh" />
              </button>
            </div>

            {identityUsersStatus ? <p className="auth-inline-status" role="status">{identityUsersStatus}</p> : null}
            <div className="auth-user-list">
              {identityUsers.map((user) => {
                const login = String(user.login || "");
                const name = String(user.name || login);
                const role = String(user.role || "user");
                const status = String(user.status || "active");
                const isCurrentUser = login === String(currentIdentityUser?.login || "");
                return (
                  <article key={login} className={`auth-user-row ${status === "active" ? "" : "is-disabled"}`}>
                    <div className="auth-user-identity">
                      <span className="auth-user-avatar"><AuthIcon name="person" /></span>
                      <span>
                        <strong>{name}</strong>
                        <span>@{login}</span>
                      </span>
                    </div>
                    <span className={`auth-status-badge ${status === "active" ? "is-active" : "is-disabled"}`}>
                      <span className="auth-status-dot" />{status === "active" ? "Active" : "Disabled"}
                    </span>
                    <div className="auth-role-control" role="group" aria-label={`Role for ${login}`}>
                      <button
                        type="button"
                        aria-pressed={role === "admin"}
                        className={role === "admin" ? "is-selected" : ""}
                        onClick={() => void updateIdentityUser(login, { role: "admin" })}
                      >
                        Admin
                      </button>
                      <button
                        type="button"
                        aria-pressed={role === "user"}
                        className={role === "user" ? "is-selected" : ""}
                        onClick={() => void updateIdentityUser(login, { role: "user" })}
                      >
                        User
                      </button>
                    </div>
                    <div className="auth-user-actions">
                      {isCurrentUser ? (
                        <button
                          type="button"
                          className="auth-text-button"
                          onClick={() => openPasswordChangeDialog(login, name)}
                        >
                          <AuthIcon name="password" /> Change password
                        </button>
                      ) : null}
                      <button
                        type="button"
                        className="auth-text-button"
                        onClick={() => void createPasswordResetToken(login)}
                      >
                        <AuthIcon name="key" /> Generate reset token
                      </button>
                      <button
                        type="button"
                        className={`auth-text-button ${status === "active" ? "is-danger" : "is-success"}`}
                        onClick={() => void updateIdentityUser(login, { status: status === "active" ? "disabled" : "active" })}
                      >
                        <AuthIcon name={status === "active" ? "person_off" : "person_check"} />
                        {status === "active" ? "Disable" : "Enable"}
                      </button>
                    </div>
                  </article>
                );
              })}
              {identityUsers.length === 0 && !identityUsersStatus ? (
                <div className="auth-empty-state">No accounts found.</div>
              ) : null}
            </div>
            {passwordResetStatus ? <p className="auth-inline-status" role="status">{passwordResetStatus}</p> : null}
          </section>

          {passwordChangeUser ? (
            <div
              className="auth-dialog-backdrop"
              role="presentation"
              onMouseDown={() => {
                if (!passwordChangeWorking) setPasswordChangeUser(null);
              }}
            >
              <form
                className="auth-dialog"
                role="dialog"
                aria-modal="true"
                aria-labelledby="auth-change-password-title"
                onMouseDown={(event) => event.stopPropagation()}
                onSubmit={(event) => {
                  event.preventDefault();
                  void changePassword();
                }}
              >
                <header className="auth-dialog-header">
                  <span>
                    <span className="auth-users-eyebrow">@{passwordChangeUser.login}</span>
                    <h4 id="auth-change-password-title">Change password for {passwordChangeUser.name}</h4>
                  </span>
                  <button
                    type="button"
                    className="auth-icon-button"
                    aria-label="Close password dialog"
                    disabled={passwordChangeWorking}
                    onClick={() => setPasswordChangeUser(null)}
                  >
                    <AuthIcon name="close" />
                  </button>
                </header>
                <label>
                  Current password
                  <input
                    autoFocus
                    type="password"
                    autoComplete="current-password"
                    value={currentPassword}
                    onChange={(event) => {
                      setCurrentPassword(event.target.value);
                      if (passwordChangeStatus) setPasswordChangeStatus("");
                    }}
                  />
                </label>
                <label>
                  New password
                  <input
                    type="password"
                    autoComplete="new-password"
                    value={newPassword}
                    onChange={(event) => {
                      setNewPassword(event.target.value);
                      if (passwordChangeStatus) setPasswordChangeStatus("");
                    }}
                  />
                </label>
                {passwordChangeStatus ? (
                  <p className="auth-inline-status" role="status">{passwordChangeStatus}</p>
                ) : null}
                <footer className="auth-dialog-actions">
                  <button
                    type="button"
                    className="auth-button"
                    disabled={passwordChangeWorking}
                    onClick={() => setPasswordChangeUser(null)}
                  >
                    Cancel
                  </button>
                  <button type="submit" className="auth-button is-primary" disabled={passwordChangeWorking}>
                    {passwordChangeWorking ? "Changing..." : "Change password"}
                  </button>
                </footer>
              </form>
            </div>
          ) : null}

          {passwordResetToken ? (
            <section className="auth-secret-banner" aria-labelledby="auth-reset-token-title">
              <AuthIcon name="key" />
              <label>
                <span id="auth-reset-token-title">New password reset token</span>
                <input readOnly value={passwordResetToken} onFocus={(event) => event.currentTarget.select()} />
              </label>
            </section>
          ) : null}

          <div className="auth-panel-grid">
            <section className="auth-panel" aria-labelledby="auth-invite-title">
              <div className="auth-section-heading">
                <span className="auth-section-icon"><AuthIcon name="person_add" /></span>
                <span className="auth-section-copy">
                  <h4 id="auth-invite-title">Invite someone</h4>
                  <span>Create a single-use registration link valid for 7 days.</span>
                </span>
              </div>
              <span className="auth-field-label">Role for the new account</span>
              <div className="auth-role-control is-wide" role="group" aria-label="Invite role">
                <button
                  type="button"
                  aria-pressed={inviteRole === "user"}
                  className={inviteRole === "user" ? "is-selected" : ""}
                  onClick={() => setInviteRole("user")}
                >
                  User
                </button>
                <button
                  type="button"
                  aria-pressed={inviteRole === "admin"}
                  className={inviteRole === "admin" ? "is-selected" : ""}
                  onClick={() => setInviteRole("admin")}
                >
                  Admin
                </button>
              </div>
              <button type="button" className="auth-button is-primary" onClick={() => void createInvite()}>
                <AuthIcon name="add_link" /> Create invite
              </button>
              {inviteStatus ? <p className="auth-inline-status" role="status">{inviteStatus}</p> : null}
              {inviteToken ? (
                <label className="auth-secret-field">
                  Invite token
                  <input readOnly value={inviteToken} onFocus={(event) => event.currentTarget.select()} />
                </label>
              ) : null}
            </section>

            <section className="auth-panel" aria-labelledby="auth-recovery-title">
              <div className="auth-section-heading">
                <span className="auth-section-icon"><AuthIcon name="health_and_safety" /></span>
                <span className="auth-section-copy">
                  <h4 id="auth-recovery-title">Account recovery</h4>
                  <span>Generate one-time codes for your own account and keep them offline.</span>
                </span>
              </div>
              <div className="auth-notice"><AuthIcon name="lock" /> Existing codes stop working after regeneration.</div>
              <button type="button" className="auth-button" onClick={() => void generateRecoveryCodes()}>
                Generate recovery codes
              </button>
              {recoveryStatus ? <p className="auth-inline-status" role="status">{recoveryStatus}</p> : null}
              {recoveryCodes.length > 0 ? (
                <textarea
                  className="auth-recovery-codes"
                  aria-label="New recovery codes"
                  readOnly
                  rows={Math.min(8, recoveryCodes.length + 1)}
                  value={recoveryCodes.join("\n")}
                />
              ) : null}
            </section>
          </div>

          <section className="auth-panel" aria-labelledby="auth-app-tokens-title">
            <div className="auth-section-heading">
              <span className="auth-section-icon"><AuthIcon name="developer_mode" /></span>
              <span className="auth-section-copy">
                <h4 id="auth-app-tokens-title">Application tokens</h4>
                <span>For Sloppy Safari and other clients. Tokens inherit your role and expire after one year.</span>
              </span>
            </div>
            <div className="auth-token-create">
              <label>
                Token name
                <input
                  value={applicationTokenName}
                  placeholder="Sloppy Safari"
                  onChange={(event) => setApplicationTokenName(event.target.value)}
                />
              </label>
              <button type="button" className="auth-button is-primary" onClick={() => void createApplicationToken()}>
                Generate token
              </button>
            </div>
            {applicationTokenStatus ? <p className="auth-inline-status" role="status">{applicationTokenStatus}</p> : null}
            {createdApplicationToken ? (
              <div className="auth-created-token">
                <label>
                  New token — copy it now
                  <input readOnly value={createdApplicationToken} onFocus={(event) => event.currentTarget.select()} />
                </label>
                <button type="button" className="auth-button" onClick={() => void copyCreatedApplicationToken()}>
                  <AuthIcon name="content_copy" /> Copy
                </button>
              </div>
            ) : null}
            <div className="auth-token-list">
              {applicationTokens.map((token) => {
                const id = String(token.id || "");
                const name = String(token.name || "Application token");
                const prefix = String(token.tokenPrefix || "");
                const expiresAt = String(token.expiresAt || "");
                const expiry = expiresAt ? new Date(expiresAt).toLocaleDateString() : "unknown";
                return (
                  <article key={id} className="auth-token-row">
                    <span className="auth-token-icon"><AuthIcon name="token" /></span>
                    <span className="auth-token-copy">
                      <strong>{name}</strong>
                      <span><code>{prefix}</code> · Expires {expiry}</span>
                    </span>
                    <button
                      type="button"
                      className="auth-text-button is-danger"
                      onClick={() => void revokeApplicationToken(id, name)}
                    >
                      <AuthIcon name="delete" /> Revoke
                    </button>
                  </article>
                );
              })}
              {applicationTokens.length === 0 ? (
                <div className="auth-empty-state">No application tokens yet.</div>
              ) : null}
            </div>
          </section>
        </>
      ) : null}
    </section>
  );
}
