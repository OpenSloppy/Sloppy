import Foundation
import Protocols

struct UsageAPIRouter: APIRouter {
    let service: CoreService
    func configure(on router: CoreRouterRegistrar) {
        router.get("/v1/usage/breakdown", metadata: RouteMetadata(summary: "Usage attribution", description: "Provider usage and locally counted tools, MCP and skill context; collection starts after upgrade", tags: ["Usage"])) { request in
            let group = request.queryParam("groupBy") ?? "tool"
            let rawFrom = request.queryParam("from"), rawTo = request.queryParam("to")
            let from = rawFrom.flatMap { CoreRouter.isoDate(from:$0) }, to = rawTo.flatMap { CoreRouter.isoDate(from:$0) }
            let rawLimit = request.queryParam("limit")
            let limit = rawLimit.flatMap(Int.init) ?? 50
            let invalidRange = from.flatMap { start in to.map { start > $0 } } ?? false
            guard ["tool","skill","server"].contains(group), (rawFrom == nil || from != nil),
                  (rawTo == nil || to != nil), (rawLimit == nil || Int(rawLimit ?? "") != nil), limit > 0, limit <= 200,
                  !invalidRange, (request.queryParam("cursor").map { UsageCallCursor.decode($0) != nil } ?? true) else {
                return CoreRouter.json(status:HTTPStatus.badRequest,payload:["error":"invalid_usage_query"])
            }
            do {
                let result = try await service.usageBreakdown(query:.init(from:from,to:to,
                    channelId:request.queryParam("channelId"),sessionId:request.queryParam("sessionId"),
                    provider:request.queryParam("provider"),model:request.queryParam("model"),serverId:request.queryParam("serverId"),
                    groupBy:group,groupId:request.queryParam("groupId"),cursor:request.queryParam("cursor"),limit:limit))
                return CoreRouter.encodable(status:HTTPStatus.ok,payload:result)
            } catch { return CoreRouter.json(status:HTTPStatus.internalServerError,payload:["error":"usage_read_failed"]) }
        }
    }
}
