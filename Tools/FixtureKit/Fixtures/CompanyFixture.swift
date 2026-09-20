@preconcurrency import CoreData
import Foundation

/// `Party` (abstract) ⟵ `Organisation`, `Person` ⟵ `Employee` ⟵ `Manager`, plus `Department` and `Tag`.
enum CompanyFixture {
    static let organisations = 3
    static let plainPeople = 35
    static let plainEmployees = 20
    static let managers = 5
    static let departments = 4
    static let tags = 8

    static func makeModel() -> NSManagedObjectModel {
        let party = entity(
            "Party", abstract: true,
            [
                attribute("name", .stringAttributeType, optional: false, defaultValue: ""),
                attribute("createdAt", .dateAttributeType),
            ])
        let organisation = entity("Organisation", parent: party, [attribute("registration", .stringAttributeType)])
        let person = entity(
            "Person", parent: party,
            [
                attribute("email", .stringAttributeType),
                attribute("age", .integer16AttributeType, defaultValue: 0),
            ])
        let employee = entity(
            "Employee", parent: person,
            [
                attribute("title", .stringAttributeType),
                attribute("salary", .decimalAttributeType),
            ])
        let manager = entity("Manager", parent: employee, [attribute("level", .integer16AttributeType)])
        let department = entity(
            "Department", [attribute("name", .stringAttributeType, optional: false, defaultValue: "")])
        let tag = entity("Tag", [attribute("label", .stringAttributeType, optional: false, defaultValue: "")])

        relate(person, "boss", .toOne, person, inverse: "reports", .toMany)
        relate(person, "tags", .toMany, tag, inverse: "people", .toMany)
        relate(department, "employees", .toMany, employee, inverse: "department", .toOne, deleteRule: .denyDeleteRule)
        relate(
            organisation, "departments", .toMany, department, inverse: "organisation", .toOne,
            deleteRule: .cascadeDeleteRule)
        relateOneWay(department, "head", .toOne, manager)

        return model([party, organisation, person, employee, manager, department, tag], identifier: "company-1")
    }

    static func build(in directory: URL) throws -> FixtureManifest {
        let writer = try StoreWriter(model: makeModel(), storeURL: directory.appendingPathComponent("Company.sqlite"))
        try writer.perform { writer in
            let tagObjects = (0..<tags).map { writer.insert("Tag", ["label": "tag-\($0)"]) }
            let organisationObjects = (0..<organisations).map { index in
                writer.insert(
                    "Organisation",
                    [
                        "name": "Organisation \(index)",
                        "registration": "REG-\(1000 + index)",
                        "createdAt": fixtureEpoch.addingTimeInterval(Double(index) * 3600),
                    ])
            }
            let departmentObjects = (0..<departments).map { index in
                writer.insert(
                    "Department",
                    ["name": "Department \(index)", "organisation": organisationObjects[index % organisations]])
            }
            let managerObjects: [NSManagedObject] = (0..<managers).map { index in
                let salary = NSDecimalNumber(string: "\(90_000 + index * 5_000).50")
                let values: [String: Any?] = [
                    "name": "Manager \(index)",
                    "email": "manager\(index)@example.org",
                    "age": Int16(40 + index),
                    "title": "Head of \(index)",
                    "salary": salary,
                    "level": Int16(index % 3 + 1),
                    "department": departmentObjects[index % departments],
                    "createdAt": fixtureEpoch.addingTimeInterval(Double(index) * 7200),
                ]
                return writer.insert("Manager", values)
            }
            for (index, department) in departmentObjects.enumerated() {
                department.setValue(managerObjects[index], forKey: "head")
            }
            let employeeObjects: [NSManagedObject] = (0..<plainEmployees).map { index in
                let salary = NSDecimalNumber(string: "\(50_000 + index * 1_250)")
                let ownTags = NSSet(array: [tagObjects[index % tags], tagObjects[(index + 3) % tags]])
                let values: [String: Any?] = [
                    "name": "Employee \(index)",
                    "email": "employee\(index)@example.org",
                    "age": Int16(22 + index),
                    "title": index % 2 == 0 ? "Engineer" : "Designer",
                    "salary": salary,
                    "department": departmentObjects[index % departments],
                    "boss": managerObjects[index % managers],
                    "tags": ownTags,
                ]
                return writer.insert("Employee", values)
            }
            for index in 0..<plainPeople {
                let email: String? = index % 4 == 0 ? nil : "person\(index)@example.org"
                let boss: NSManagedObject? = index % 3 == 0 ? employeeObjects[index % plainEmployees] : nil
                let ownTags = index % 2 == 0 ? NSSet(array: [tagObjects[index % tags]]) : NSSet()
                let values: [String: Any?] = [
                    "name": "Person \(index)",
                    "email": email,
                    "age": Int16(18 + index),
                    "boss": boss,
                    "tags": ownTags,
                ]
                writer.insert("Person", values)
            }
        }
        try writer.close()

        let employees = plainEmployees + managers
        let people = plainPeople + employees
        return FixtureManifest(
            fixture: .company,
            summary: "Inheritance three levels deep under an abstract root, and every kind of relationship.",
            store: "Company.sqlite",
            entityCounts: [
                "Party": people + organisations,
                "Organisation": organisations,
                "Person": people,
                "Employee": employees,
                "Manager": managers,
                "Department": departments,
                "Tag": tags,
            ]
        )
    }
}
