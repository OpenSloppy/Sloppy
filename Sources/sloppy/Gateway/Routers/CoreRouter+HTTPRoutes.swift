import Foundation

extension CoreRouter {
    static func defaultRoutes(service: CoreService) -> [RouteDefinition] {
        let router = CoreRouterRegistrar()
        var routers: [APIRouter] = [
            AuthAPIRouter(service: service),
            ConsoleAPIRouter(service: service),
            SystemAPIRouter(service: service),
            UsageAPIRouter(service: service),
            ChannelsAPIRouter(service: service),
            SessionsAPIRouter(service: service),
            LongChatAPIRouter(service: service),
            ProjectsAPIRouter(service: service),
            InitiativesAPIRouter(service: service),
            ProjectAutomationsAPIRouter(service: service),
            ProjectWorkflowsAPIRouter(service: service),
            TasksAPIRouter(service: service),
            NodeMeshAPIRouter(service: service),
            ProvidersAPIRouter(service: service),
            GitHubAPIRouter(service: service),
            TaskSyncAPIRouter(service: service),
            ACPAPIRouter(service: service),
            AgentsAPIRouter(service: service),
            LaunchAPIRouter(service: service),
            ProactivityAPIRouter(service: service),
            WorkspaceBrowserAPIRouter(service: service),
            DesktopComputerAPIRouter(service: service),
            MemoryAPIRouter(service: service),
            MemoryImportsAPIRouter(service: service),
            MigrationsAPIRouter(service: service),
            ActorsAPIRouter(service: service),
            CronAPIRouter(service: service),
            SkillsAPIRouter(service: service),
            AgentPluginsAPIRouter(service: service),
            ArtifactsAPIRouter(service: service),
            SitesAPIRouter(service: service),
            WorkspacesAPIRouter(service: service),
            SourceControlAPIRouter(service: service),
            CodeReviewAPIRouter(service: service),
            PluginsAPIRouter(service: service)
        ]

        if !SloppyVersion.isReleaseBuild {
            routers.append(DebugAPIRouter(service: service))
        }

        for apiRouter in routers {
            apiRouter.configure(on: router)
        }

        return router.routes
    }
}
