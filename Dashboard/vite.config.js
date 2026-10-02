import { defineConfig } from "vite";
import fs from "node:fs";
import path from "node:path";
import { resolveDashboardPaths } from "./vite.paths.js";

const { dashboardDir, packageJsonPath, dashboardConfigPath, distDir } = resolveDashboardPaths(import.meta.url);
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf-8"));

function dashboardConfigPlugin() {
  return {
    name: "dashboard-config-json",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url !== "/config.json") {
          next();
          return;
        }

        fs.readFile(dashboardConfigPath, "utf-8", (error, content) => {
          if (error) {
            res.statusCode = 404;
            res.end();
            return;
          }

          res.setHeader("Content-Type", "application/json; charset=utf-8");
          res.end(content);
        });
      });
    },
    writeBundle() {
      fs.mkdirSync(distDir, { recursive: true });
      fs.copyFileSync(dashboardConfigPath, path.resolve(distDir, "config.json"));
    }
  };
}

export default defineConfig(({ command, mode }) => ({
  root: dashboardDir,
  plugins: [dashboardConfigPlugin()],
  define: {
    __APP_VERSION__: JSON.stringify(packageJson.version),
    __DASHBOARD_DEV__: JSON.stringify(command === "serve" || mode === "development"),
  },
  server: {
    port: 25102,
    host: true
  },
  build: {
    outDir: distDir,
    rollupOptions: {
      onwarn(warning, defaultHandler) {
        if (
          warning.code === "MODULE_LEVEL_DIRECTIVE" &&
          typeof warning.message === "string" &&
          warning.message.includes('"use client"')
        ) {
          return;
        }
        defaultHandler(warning);
      }
    }
  }
}));
