import Foundation

public enum LaunchPlatform: String, Codable, Sendable, CaseIterable {
    case web, macOS, iOSSimulator
}

public struct LaunchCommand: Codable, Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// User/agent input. Execution identity is assigned by Core, never by the caller.
public struct LaunchConfigurationRequest: Codable, Sendable, Equatable {
    public var id: String?
    public var name: String
    public var target: String
    public var platform: LaunchPlatform
    public var checkoutPath: String
    public var workingDirectory: String
    public var build: [LaunchCommand]
    public var launch: LaunchCommand?
    public var appPath: String?
    public var bundleID: String?
    public var simulatorID: String?
    public var webPort: Int?
    public var webPath: String?
    public var verificationEvidenceIDs: [String]?

    public init(id: String? = nil, name: String, target: String, platform: LaunchPlatform,
                checkoutPath: String, workingDirectory: String = ".", build: [LaunchCommand] = [],
                launch: LaunchCommand? = nil, appPath: String? = nil, bundleID: String? = nil,
                simulatorID: String? = nil, webPort: Int? = nil, webPath: String? = nil,
                verificationEvidenceIDs: [String]? = nil) {
        self.id = id; self.name = name; self.target = target; self.platform = platform
        self.checkoutPath = checkoutPath; self.workingDirectory = workingDirectory; self.build = build
        self.launch = launch; self.appPath = appPath; self.bundleID = bundleID; self.simulatorID = simulatorID
        self.webPort = webPort; self.webPath = webPath; self.verificationEvidenceIDs = verificationEvidenceIDs
    }
}

public struct LaunchConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var agentID: String
    public var sessionID: String
    public var projectID: String?
    public var hostName: String
    public var request: LaunchConfigurationRequest
    public var updatedAt: Date
    public var verificationEvidence: [LaunchVerificationEvidence]?

    public init(id: String, agentID: String, sessionID: String, projectID: String? = nil, hostName: String,
                request: LaunchConfigurationRequest, updatedAt: Date, verificationEvidence: [LaunchVerificationEvidence]? = nil) {
        self.id = id; self.agentID = agentID; self.sessionID = sessionID; self.projectID = projectID
        self.hostName = hostName; self.request = request; self.updatedAt = updatedAt
        self.verificationEvidence = verificationEvidence
    }
}

public enum LaunchRunStatus: String, Codable, Sendable {
    case preparing, building, launching, running, completed, stopped, failed
    public var isActive: Bool {
        switch self {
        case .preparing, .building, .launching, .running: true
        default: false
        }
    }
}

public struct LaunchRun: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var configurationID: String
    public var configuration: LaunchConfiguration
    public var status: LaunchRunStatus
    public var buildSucceeded: Bool
    public var launchSucceeded: Bool
    public var logs: String
    public var error: String?
    public var previewURL: String?
    public var processID: Int?
    public var startedAt: Date
    public var finishedAt: Date?
    public init(id: String, configurationID: String, configuration: LaunchConfiguration, status: LaunchRunStatus,
                buildSucceeded: Bool, launchSucceeded: Bool, logs: String, error: String? = nil,
                previewURL: String? = nil, processID: Int? = nil, startedAt: Date, finishedAt: Date? = nil) {
        self.id = id; self.configurationID = configurationID; self.configuration = configuration; self.status = status
        self.buildSucceeded = buildSucceeded; self.launchSucceeded = launchSucceeded; self.logs = logs; self.error = error
        self.previewURL = previewURL; self.processID = processID; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public struct LaunchSessionState: Codable, Sendable, Equatable {
    public var agentID: String
    public var sessionID: String
    public var configurations: [LaunchConfiguration] = []
    public var recommendedConfigurationID: String?
    public var selectedConfigurationID: String?
    public var isArchived: Bool = false
    public var selectionIsExplicit: Bool = false
    public var runs: [LaunchRun] = []
    public init(agentID: String, sessionID: String) {
        self.agentID = agentID; self.sessionID = sessionID
    }
    enum CodingKeys: String, CodingKey {
        case agentID, sessionID, configurations, recommendedConfigurationID, selectedConfigurationID, selectionIsExplicit, isArchived, runs
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try values.decode(String.self, forKey: .agentID)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        configurations = try values.decodeIfPresent([LaunchConfiguration].self, forKey: .configurations) ?? []
        recommendedConfigurationID = try values.decodeIfPresent(String.self, forKey: .recommendedConfigurationID)
        selectedConfigurationID = try values.decodeIfPresent(String.self, forKey: .selectedConfigurationID)
        selectionIsExplicit = try values.decodeIfPresent(Bool.self, forKey: .selectionIsExplicit) ?? false
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        runs = try values.decodeIfPresent([LaunchRun].self, forKey: .runs) ?? []
    }
    public var selectedConfiguration: LaunchConfiguration? {
        configurations.first { $0.id == (selectedConfigurationID ?? recommendedConfigurationID) }
    }
}

public struct LaunchSelectionRequest: Codable, Sendable {
    public var configurationID: String
    public var simulatorID: String?
    public init(configurationID: String, simulatorID: String? = nil) {
        self.configurationID = configurationID; self.simulatorID = simulatorID
    }
}

public struct LaunchSimulator: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var state: String
    public init(id: String, name: String, state: String) { self.id = id; self.name = name; self.state = state }
}

public struct LaunchVerificationEvidence: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var tool: String
    public var command: String?
    public var arguments: [String]
    public var cwd: String?
    public var exitCode: Int?
    public var observedAt: String
}

public struct LaunchArchiveRequest: Codable, Sendable {
    public var isArchived: Bool
    public init(isArchived: Bool) { self.isArchived = isArchived }
}
