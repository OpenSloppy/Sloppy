import { defineConfig } from "vitepress";

export default defineConfig({
  title: "Sloppy Docs",
  description: "Runtime specifications, ADRs, and implementation notes for Sloppy.",
  base: "/",
  lang: "en-US",
  markdown: {
    theme: {
      light: "vesper",
      dark: "vesper"
    }
  },
  cleanUrls: true,
  lastUpdated: true,
  appearance: false,
  srcExclude: ["product/**/*.md"],
  ignoreDeadLinks: false,
  head: [
    ["link", { rel: "preconnect", href: "https://fonts.googleapis.com" }],
    ["link", { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "" }],
    ["link", { rel: "icon", type: "image/svg+xml", href: "/so_logo.svg" }],
    ["link", { rel: "stylesheet", href: "https://fonts.googleapis.com/css2?family=Fira+Code:wght@300..700&display=swap" }]
  ],
  themeConfig: {
    logo: "/so_logo.svg",
    nav: [
      { text: "Guides", link: "/guides/build-from-terminal" },
      { text: "TUI", link: "/tui/overview" },
      { text: "API", link: "/api/reference" },
      { text: "Agents", link: "/agents/memory" },
      { text: "Visor", link: "/visor/overview" },
      { text: "Design", link: "/architecture/project-design" },
      { text: "Specs", link: "/specs/channel-plugin-protocol" },
      { text: "Visual Design", link: "/dashboard-style" },
      { text: "Licensing", link: "/licensing" }
    ],
    sidebar: [
      {
        text: "Overview",
        items: [
          { text: "What is Sloppy?", link: "/" },
          { text: "Install", link: "/install" },
          { text: "Licensing", link: "/licensing" },
          { text: "Visual Design", link: "/dashboard-style" },
          { text: "Agent chat (Dashboard)", link: "/dashboard/agent-chat" },
          { text: "API Reference", link: "/api/reference" }
        ]
      },
      {
        text: "Guides",
        items: [
          { text: "Build From Terminal", link: "/guides/build-from-terminal" },
          { text: "Build With Docker", link: "/guides/build-with-docker" },
          { text: "Development Workflow", link: "/guides/development-workflow" },
          { text: "Project Context", link: "/guides/project-context" },
          { text: "CLI Reference", link: "/guides/cli" },
          { text: "SloppyNode", link: "/guides/sloppy-node" },
          { text: "Relay Deployment", link: "/guides/relay" },
          { text: "SloppyNode Mesh", link: "/guides/mesh" },
          { text: "Model Providers", link: "/guides/models" },
          { text: "MCP Integration", link: "/guides/mcp" },
          { text: "ACP Integration", link: "/guides/acp" },
          { text: "SDK", link: "/guides/sdk" },
          { text: "Plugins", link: "/guides/plugins" },
          { text: "Git & Repositories", link: "/guides/git" }
        ]
      },
      {
        text: "TUI",
        items: [
          { text: "Terminal UI", link: "/tui/overview" },
          { text: "Multi-session TUI", link: "/tui/multi-session" }
        ]
      },
      {
        text: "Channels",
        items: [
          { text: "About Channels", link: "/channels/about" },
          { text: "Setup Telegram", link: "/channels/setup-telegram" },
          { text: "Setup Discord", link: "/channels/setup-discord" }
        ]
      },
      {
        text: "Agents",
        items: [
          { text: "Memory", link: "/agents/memory" },
          { text: "Context Compactor", link: "/agents/context-compactor" },
          { text: "Runtime", link: "/agents/runtime" },
          { text: "Workspace", link: "/agents/workspace" },
          { text: "Sloppies", link: "/agents/sloppies" }
        ]
      },
      {
        text: "Visor",
        items: [
          { text: "Overview", link: "/visor/overview" },
          { text: "Memory and bulletins", link: "/visor/memory" },
          { text: "Configuration", link: "/visor/configuration" }
        ]
      },
      {
        text: "Architecture",
        items: [
          { text: "Project Design", link: "/architecture/project-design" },
          { text: "Enterprise Extension Boundary", link: "/architecture/enterprise-extension-boundary" },
          { text: "Actors Board", link: "/architecture/actors-board" },
          { text: "Swarm", link: "/architecture/swarm" },
        ]
      },
      {
        text: "Specifications",
        items: [
          { text: "Channel Plugin Protocol v1", link: "/specs/channel-plugin-protocol" },
          { text: "PRD Runtime v1", link: "/specs/prd-runtime-v1" }
        ]
      }
    ],
    socialLinks: [
      { icon: "github", link: "https://github.com/TeamSloppy/Sloppy" }
    ],
    outline: {
      level: [2, 3],
      label: "On this page"
    },
    search: {
      provider: "local"
    },
    footer: {
      message: "Sloppy Community is AGPL-3.0-only; public SDK and native-client surfaces are MIT licensed.",
      copyright: "Sloppy"
    }
  }
});
