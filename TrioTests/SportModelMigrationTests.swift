import CoreData
import Foundation
import Testing

@testable import Trio

@Suite("Sport model migration") struct SportModelMigrationTests {
    @Test("An existing SQLite store migrates while keeping override data") func migrateExistingStore() async throws {
        let bundle = Bundle(for: CoreDataStack.self)
        let modelDirectory = try #require(bundle.url(forResource: "TrioCoreDataPersistentContainer", withExtension: "momd"))
        let oldModel =
            try #require(NSManagedObjectModel(
                contentsOf: modelDirectory
                    .appendingPathComponent("TrioCoreDataPersistentContainer.mom")
            ))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.sqlite")
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(type: .sqlite, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        try await oldContext.perform {
            let record = NSEntityDescription.insertNewObject(forEntityName: "OverrideStored", into: oldContext)
            record.setValue("existing-preset", forKey: "id")
            record.setValue(true, forKey: "isPreset")
            record.setValue(60, forKey: "duration")
            record.setValue(85, forKey: "percentage")
            try oldContext.save()
            oldContext.reset()
        }
        try oldCoordinator.remove(oldStore)
        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataStack.managedObjectModel)
        let newStore = try newCoordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: url,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let newContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        newContext.persistentStoreCoordinator = newCoordinator
        try await newContext.perform {
            let records = try newContext.fetch(OverrideStored.fetchRequest())
            let record = try #require(records.first)
            #expect(records.count == 1 && record.id == "existing-preset")
            #expect(record.isPreset && record.duration == 60 && record.percentage == 85)
            #expect(record.sportRuleID == nil)
            record.sportRuleID = UUID()
            try newContext.save()
            newContext.reset()
            #expect(try newContext.fetch(OverrideStored.fetchRequest()).first?.sportRuleID != nil)
        }
        try newCoordinator.remove(newStore)
    }
}
