// OpenGroups.swift
// 1.0.0-alpha.4: which files go to which application in ONE open request.
// Opening files one request per file makes Photoshop run Camera Raw once per file (Done, then the
// next file appears). One request with all the files gives one Camera Raw session with a filmstrip.
// Platform-independent: the caller supplies how an application is found for a file.

import Foundation

struct OpenGroup: Equatable {
    /// Application path, or nil when none is known (the caller opens those files one by one).
    let app: String?
    let paths: [String]
}

enum OpenGroups {
    /// Groups paths by application, keeping the selection order inside each group and ordering groups
    /// by their first file. `appForExtension` is asked once per lowercased extension (no file access).
    static func group(_ paths: [String], appForExtension: (String) -> String?) -> [OpenGroup] {
        var appByExt: [String: String?] = [:]
        var order: [String] = []          // group keys in order of first appearance
        var byKey: [String: (app: String?, paths: [String])] = [:]
        for p in paths {
            let ext = (p as NSString).pathExtension.lowercased()
            let app: String?
            if let known = appByExt[ext] {
                app = known
            } else {
                app = ext.isEmpty ? nil : appForExtension(ext)
                appByExt[ext] = app
            }
            // Files without a known application each get their own group.
            let key = app.map { "app:" + $0 } ?? "none:" + p
            if byKey[key] == nil {
                byKey[key] = (app, [])
                order.append(key)
            }
            byKey[key]!.paths.append(p)
        }
        return order.map { OpenGroup(app: byKey[$0]!.app, paths: byKey[$0]!.paths) }
    }

    /// The same, with every path going to one chosen application (Open With).
    static func all(_ paths: [String], app: String) -> [OpenGroup] {
        return paths.isEmpty ? [] : [OpenGroup(app: app, paths: paths)]
    }
}
