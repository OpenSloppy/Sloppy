export type MigrationCategory = "skill" | "mcp" | "project" | "session" | "memory" | "instructions";
export type MigrationSourceKind = "codex" | "claude" | "openclaw" | "hermes";
export interface MigrationSource { id: string; kind: MigrationSourceKind; path: string; readable: boolean }
export interface MigrationItem {
  id: string; source: MigrationSource; externalID: string; profile: string; category: MigrationCategory; title: string;
  projectPath?: string; files: Array<{ path: string; content: string; executable: boolean }>;
  messages: Array<{ id: string; text: string; kind: string; createdAt: string }>;
  mcp?: { command?: string; endpoint?: string }; warnings: string[];
}
export interface MigrationCatalog { sources: MigrationSource[]; items: MigrationItem[]; warnings: string[] }
export interface MigrationSelection { warnings?: string[]; items: MigrationItem[]; agentMappings: Record<string, string>; projectMappings: Record<string, string> }
export interface MigrationPreview { totalBytes: number; counts: Record<string, number>; duplicates: string[]; conflicts: string[]; warnings: string[] }
export interface MigrationOutcome { id: string; category: MigrationCategory; title: string; status: string; agentID?: string; projectID?: string; sessionID?: string; mcpID?: string; message?: string }
export interface MigrationJob {
  id: string; destination: string; status: string; stage: string; totalItems: number; totalBytes: number; uploadedBytes: number;
  outcomes: MigrationOutcome[]; warnings: string[]; memoryCompletedUnits: number; memoryTotalUnits: number; createdAt: string;
}
