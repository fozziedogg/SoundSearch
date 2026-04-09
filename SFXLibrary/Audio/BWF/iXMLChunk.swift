import Foundation

struct iXMLFields {
    var scene:       String?
    var take:        String?
    var tapeName:    String?
    var note:        String?
    // UCS (Universal Category System) fields
    var ucsCategory:    String?
    var ucsSubCategory: String?
}

struct iXMLChunk {
    static func parse(from data: Data) -> iXMLFields {
        guard let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement() else { return iXMLFields() }

        func text(_ xpath: String) -> String? {
            (try? root.nodes(forXPath: xpath))?.first.flatMap {
                ($0 as? XMLElement)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.flatMap { $0.isEmpty ? nil : $0 }
        }

        return iXMLFields(
            scene:          text("//SCENE"),
            take:           text("//TAKE"),
            tapeName:       text("//TAPE"),
            note:           text("//NOTE"),
            ucsCategory:    text("//CATEGORY"),
            ucsSubCategory: text("//SUBCATEGORY")
        )
    }

    /// Update fields in existing iXML data (or create minimal iXML if none exists).
    static func updated(existing xmlData: Data?, with fields: iXMLFields) -> Data {
        let doc: XMLDocument
        if let existing = xmlData,
           let parsed = try? XMLDocument(data: existing, options: []) {
            doc = parsed
        } else {
            let root = XMLElement(name: "BWFXML")
            doc = XMLDocument(rootElement: root)
        }

        guard let root = doc.rootElement() else { return xmlData ?? Data() }

        func set(_ value: String?, tag: String) {
            guard let v = value else { return }
            // Remove existing node if present
            (try? root.nodes(forXPath: "//\(tag)"))?.forEach { $0.detach() }
            let el = XMLElement(name: tag, stringValue: v)
            root.addChild(el)
        }

        set(fields.scene,    tag: "SCENE")
        set(fields.take,     tag: "TAKE")
        set(fields.tapeName, tag: "TAPE")
        set(fields.note,     tag: "NOTE")

        return doc.xmlData(options: .nodePrettyPrint)
    }
}
