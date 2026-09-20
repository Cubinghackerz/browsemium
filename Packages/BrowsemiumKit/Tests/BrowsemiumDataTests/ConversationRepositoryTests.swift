import BrowsemiumCore
import BrowsemiumData
import Foundation
import Testing

@Test
func conversationsRoundTripInTheProfileDatabase() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = AIConversationRepository(database: database)

    let id = try repository.createConversation(title: "What is this page?")
    try repository.appendMessage(conversationID: id, role: .user, content: "What is this page?")
    try repository.appendMessage(conversationID: id, role: .assistant, content: "It is a README.")

    let summaries = try repository.conversations()
    #expect(summaries.count == 1)
    #expect(summaries.first?.id == id)
    #expect(summaries.first?.title == "What is this page?")

    let messages = try repository.messages(conversationID: id)
    #expect(messages.count == 2)
    #expect(messages.first?.role == .user)
    #expect(messages.last?.role == .assistant)
    #expect(messages.last?.content == "It is a README.")
}

@Test
func deletingAConversationRemovesItsMessages() throws {
    let database = try AppDatabase.inMemoryProfile()
    let repository = AIConversationRepository(database: database)
    let id = try repository.createConversation(title: "Temp")
    try repository.appendMessage(conversationID: id, role: .user, content: "hi")

    try repository.delete(conversationID: id)
    #expect(try repository.conversations().isEmpty)
    #expect(try repository.messages(conversationID: id).isEmpty)
}

@Test
func conversationsAreScopedPerProfile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("browsemium-chat-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let root = try AppDatabase(path: directory.appendingPathComponent("root.sqlite").path)
    let store = ProfileStore(root: root, directory: directory.appendingPathComponent("profiles"))
    try store.splitIfNeeded()

    let personal = try #require(try store.profiles().first)
    let work = try store.create(name: "Work")

    let personalChats = AIConversationRepository(database: try store.database(for: personal))
    let workChats = AIConversationRepository(database: try store.database(for: work))

    let personalID = try personalChats.createConversation(title: "Personal chat")
    try personalChats.appendMessage(conversationID: personalID, role: .user, content: "hello")

    #expect(try workChats.conversations().isEmpty)
    #expect(try personalChats.conversations().count == 1)
}
