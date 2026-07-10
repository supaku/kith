import ContactsCore
import Foundation
import KithAgentProtocol
import KithMessagesService
import MessagesCore
import ResolveCore   // pulls in `KithPhoneNumberNormalizer: PhoneNumberNormalizing`
import SecureXPC

// kith-agent
//
// Long-lived process that holds the user-facing TCC grants (Contacts,
// Full Disk Access for chat.db) and vends ContactsStore + MessageStore
// access to the CLI over XPC. The CLI itself never asks TCC for anything;
// Kith.app is the responsible bundle and the agent inherits its grants.
//
// In v0.2.0 production this binary lives at
//   Kith.app/Contents/MacOS/KithAgent
// and is registered via `SMAppService.agent(plistName:).register()` from
// the Kith.app GUI bootstrap target.

let agentVersion = "0.2.4"

let normalizer = KithPhoneNumberNormalizer()
let contactsStore = CNBackedContactsStore(normalizer: normalizer)

let server: XPCServer
do {
    let criteria = try XPCServer.MachServiceCriteria(
        machServiceName: kithAgentMachServiceName,
        clientRequirement: XPCServer.ClientRequirement.sameTeamIdentifier
    )
    server = try XPCServer.forMachService(withCriteria: criteria)
} catch {
    FileHandle.standardError.write(Data("kith-agent: bind \(kithAgentMachServiceName) failed: \(error)\n".utf8))
    exit(1)
}

// Open MessageStore lazily per request — the database is read-only and
// cheap to re-open. Avoids holding a stale connection if the file rotates
// (e.g. during Time Machine restore).
func openMessages() throws -> MessageStore {
    do { return try MessageStore(path: MessageStore.kithDefaultPath) }
    catch { throw KithWireError.dbUnavailable(String(describing: error)) }
}

// MARK: - contacts.* routes

server.registerRoute(AgentRoutes.find) { (query: ContactsQuery) async throws -> [Contact] in
    return try KithMessagesService.contactsFind(contacts: contactsStore, query: query)
}

server.registerRoute(AgentRoutes.contactsGet) { (id: String) async throws -> OptionalContact in
    return OptionalContact(try KithMessagesService.contactsGet(contacts: contactsStore, id: id))
}

server.registerRoute(AgentRoutes.contactsListGroups) { () async throws -> [ContactGroup] in
    return try KithMessagesService.contactsListGroups(contacts: contactsStore)
}

server.registerRoute(AgentRoutes.contactsGroupMembers) { (q: ContactsGroupMembersQuery) async throws -> [Contact] in
    return try KithMessagesService.contactsGroupMembers(contacts: contactsStore, groupID: q.groupID, limit: q.limit)
}

server.registerRoute(AgentRoutes.contactsGroupsByName) { (name: String) async throws -> [ContactGroup] in
    return try KithMessagesService.contactsGroupsByName(contacts: contactsStore, name: name)
}

// MARK: - messages.* routes

server.registerRoute(AgentRoutes.messagesChats) { (q: MessagesChatsQuery) async throws -> [KithChat] in
    let messages = try openMessages()
    return try KithMessagesService.messagesChats(
        contacts: contactsStore,
        messages: messages,
        normalizer: normalizer,
        query: q
    )
}

server.registerRoute(AgentRoutes.messagesHistory) { (q: MessagesHistoryQuery) async throws -> MessagesHistoryResult in
    let messages = try openMessages()
    return try KithMessagesService.messagesHistory(
        contacts: contactsStore,
        messages: messages,
        normalizer: normalizer,
        query: q
    )
}

// MARK: - system.* routes

server.registerRoute(AgentRoutes.systemPing) { () async throws -> String in
    return agentVersion
}

server.registerRoute(AgentRoutes.systemHealth) { () async throws -> AgentHealthReport in
    let auth: String = {
        switch contactsStore.authorizationStatus() {
        case .granted:       return "granted"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "not-determined"
        }
    }()

    let total: Int
    if auth == "granted" {
        total = (try? contactsStore.totalContacts) ?? 0
    } else {
        total = 0
    }

    let dbPath = MessageStore.kithDefaultPath
    var dbOpenable = false
    var schemaFlags: [String: Bool] = [:]
    if FileManager.default.fileExists(atPath: dbPath) {
        if let mstore = try? MessageStore(path: dbPath) {
            dbOpenable = true
            let flags = mstore.kithSchemaFlags
            schemaFlags = [
                "hasAttributedBody": flags.hasAttributedBody,
                "hasReactionColumns": flags.hasReactionColumns,
                "hasThreadOriginatorGUIDColumn": flags.hasThreadOriginatorGUIDColumn,
                "hasDestinationCallerID": flags.hasDestinationCallerID,
            ]
        }
    }

    return AgentHealthReport(
        agentVersion: agentVersion,
        contactsAuthStatus: auth,
        totalContacts: total,
        messagesDbPath: dbPath,
        messagesDbOpenable: dbOpenable,
        schemaFlags: schemaFlags
    )
}

// SecureXPC's setErrorHandler closure is `@isolated(any) async` and crashes
// under Swift 6 strict concurrency when invoked from arbitrary queues.
// Letting SecureXPC use its default (logs to stderr) is fine for now.

FileHandle.standardError.write(Data("kith-agent \(agentVersion): listening on \(kithAgentMachServiceName)\n".utf8))
server.startAndBlock()
