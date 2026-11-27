// InPlaceMeta.swift
// 0.18.8 (Settings > Photography > "Faster: change the metadata in place", off by default): instead of
// rewriting the whole picture file (ExifTool always does), Find changes only the metadata part:
//   - TIFF-based RAW (NEF, NRW, DNG, ARW, PEF) and TIFF: the new XMP / IPTC block is written where the
//     old one was if it fits, or at the end of the file, and then the 12-byte directory entry that
//     points to it is updated (and, only when the file had no such entry yet, a copy of the first
//     directory with the new entry is added at the end and the 4-byte pointer to it is updated).
//   - JPEG: only when the new XMP (and IPTC) fit exactly into the space the old ones take (XMP packets
//     usually carry padding for this); otherwise the normal checked rewrite is used.
// The picture data is never written: every write is inside the old metadata blocks, past the old end
// of the file, or a directory entry/pointer. This file only PLANS the writes (pure Foundation, tested
// with the real ExifTool on Linux); FileOperations saves the bytes it will overwrite in a note first,
// does the writes through the platform, reads the values back, and puts the old bytes back if anything
// is not as asked. nil from a planner = this file can't be done in place (the normal way is used).

import Foundation

// MARK: - A tiny XML tree that keeps everything it doesn't change exactly as it was

final class XElement {
    var name: String
    var attrs: [(name: String, raw: String)]      // raw = still escaped, as in the file
    var children: [XNode]
    init(name: String, attrs: [(name: String, raw: String)] = [], children: [XNode] = []) {
        self.name = name
        self.attrs = attrs
        self.children = children
    }
    var elements: [XElement] { return children.compactMap { if case .element(let e) = $0 { return e }; return nil } }
}

enum XNode {
    case element(XElement)
    case text(String)        // raw (escaped) text
    case other(String)       // comment, processing instruction, CDATA, doctype - kept verbatim
}

enum MiniXML {
    static func escape(_ s: String) -> String {
        var o = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&apos;"
            default: o.unicodeScalars.append(c)
            }
        }
        return o
    }

    static func unescape(_ s: String) -> String {
        if !s.contains("&") { return s }
        var o = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].index(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let ent = String(s[s.index(after: i)..<semi])
                var rep: String? = nil
                switch ent {
                case "amp": rep = "&"
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "quot": rep = "\""
                case "apos": rep = "'"
                default:
                    if ent.hasPrefix("#x") || ent.hasPrefix("#X"), let v = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(u) }
                    else if ent.hasPrefix("#"), let v = UInt32(ent.dropFirst()), let u = Unicode.Scalar(v) { rep = String(u) }
                }
                if let r = rep { o += r; i = s.index(after: semi); continue }
            }
            o.append(s[i])
            i = s.index(after: i)
        }
        return o
    }

    /// Parse a fragment (any number of top-level nodes). nil = not well-formed enough to edit safely.
    static func parse(_ s: String) -> [XNode]? {
        let u = Array(s.unicodeScalars)
        var i = 0
        func starts(_ t: String) -> Bool {
            let tu = Array(t.unicodeScalars)
            if i + tu.count > u.count { return false }
            for k in 0..<tu.count where u[i + k] != tu[k] { return false }
            return true
        }
        func upTo(_ t: String) -> Int? {
            let tu = Array(t.unicodeScalars)
            var k = i
            while k + tu.count <= u.count {
                var ok = true
                for m in 0..<tu.count where u[k + m] != tu[m] { ok = false; break }
                if ok { return k }
                k += 1
            }
            return nil
        }
        func str(_ a: Int, _ b: Int) -> String { var r = ""; r.unicodeScalars.append(contentsOf: u[a..<b]); return r }
        func isSpace(_ c: Unicode.Scalar) -> Bool { return c == " " || c == "\n" || c == "\r" || c == "\t" }
        var stack: [XElement] = []
        var top: [XNode] = []
        func add(_ n: XNode) { if let e = stack.last { e.children.append(n) } else { top.append(n) } }
        while i < u.count {
            if u[i] != "<" {
                let a = i
                while i < u.count && u[i] != "<" { i += 1 }
                add(.text(str(a, i)))
                continue
            }
            if starts("<!--") {
                guard let e = upTo("-->") else { return nil }
                add(.other(str(i, e + 3))); i = e + 3; continue
            }
            if starts("<![CDATA[") {
                guard let e = upTo("]]>") else { return nil }
                add(.other(str(i, e + 3))); i = e + 3; continue
            }
            if starts("<?") {
                guard let e = upTo("?>") else { return nil }
                add(.other(str(i, e + 2))); i = e + 2; continue
            }
            if starts("<!") {
                guard let e = upTo(">") else { return nil }
                add(.other(str(i, e + 1))); i = e + 1; continue
            }
            if starts("</") {
                i += 2
                let a = i
                while i < u.count && u[i] != ">" && !isSpace(u[i]) { i += 1 }
                let name = str(a, i)
                while i < u.count && u[i] != ">" { i += 1 }
                guard i < u.count, let open = stack.popLast(), open.name == name else { return nil }
                i += 1
                add(.element(open))
                continue
            }
            // Start tag.
            i += 1
            let a = i
            while i < u.count && !isSpace(u[i]) && u[i] != ">" && u[i] != "/" { i += 1 }
            let el = XElement(name: str(a, i))
            if el.name.isEmpty { return nil }
            var closed = false
            while true {
                while i < u.count && isSpace(u[i]) { i += 1 }
                guard i < u.count else { return nil }
                if u[i] == ">" { i += 1; break }
                if u[i] == "/" {
                    guard i + 1 < u.count, u[i + 1] == ">" else { return nil }
                    i += 2; closed = true; break
                }
                let na = i
                while i < u.count && u[i] != "=" && !isSpace(u[i]) && u[i] != ">" { i += 1 }
                let an = str(na, i)
                while i < u.count && isSpace(u[i]) { i += 1 }
                guard i < u.count, u[i] == "=" else { return nil }
                i += 1
                while i < u.count && isSpace(u[i]) { i += 1 }
                guard i < u.count, u[i] == "\"" || u[i] == "'" else { return nil }
                let q = u[i]
                i += 1
                let va = i
                while i < u.count && u[i] != q { i += 1 }
                guard i < u.count else { return nil }
                el.attrs.append((an, str(va, i)))
                i += 1
            }
            if closed { add(.element(el)) } else { stack.append(el) }
        }
        return stack.isEmpty ? top : nil
    }

    static func serialize(_ nodes: [XNode]) -> String {
        var o = ""
        func w(_ n: XNode) {
            switch n {
            case .text(let t): o += t
            case .other(let t): o += t
            case .element(let e):
                o += "<" + e.name
                for a in e.attrs { o += " " + a.name + "=\"" + a.raw.replacingOccurrences(of: "\"", with: "&quot;") + "\"" }
                if e.children.isEmpty { o += "/>"; return }
                o += ">"
                for c in e.children { w(c) }
                o += "</" + e.name + ">"
            }
        }
        for n in nodes { w(n) }
        return o
    }
}

// MARK: - XMP: change only our properties, keep everything else

enum XMPEditor {
    static let rdfNS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    enum Kind { case simple, alt, bag, seq }
    /// 0.18.13: a structure some of our fields live in (Photo Mechanic's contact info; Location Created,
    /// a list of locations of which Find edits the one - as ExifTool does).
    struct Parent {
        let ns: String
        let prefix: String
        let local: String
        let inBag: Bool
    }
    struct Prop {
        let ns: String
        let prefix: String
        let local: String
        let kind: Kind
        let parent: Parent?
        init(ns: String, prefix: String, local: String, kind: Kind, parent: Parent? = nil) {
            self.ns = ns; self.prefix = prefix; self.local = local; self.kind = kind; self.parent = parent
        }
    }

    static let nsDC = "http://purl.org/dc/elements/1.1/"
    static let nsPS = "http://ns.adobe.com/photoshop/1.0/"
    static let nsRights = "http://ns.adobe.com/xap/1.0/rights/"
    static let nsCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
    static let nsExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    static let contactInfo = Parent(ns: nsCore, prefix: "Iptc4xmpCore", local: "CreatorContactInfo", inBag: false)
    static let locationCreated = Parent(ns: nsExt, prefix: "Iptc4xmpExt", local: "LocationCreated", inBag: true)

    static func prop(_ f: MetaField) -> Prop {
        func ps(_ l: String, _ k: Kind = .simple) -> Prop { return Prop(ns: nsPS, prefix: "photoshop", local: l, kind: k) }
        func core(_ l: String) -> Prop { return Prop(ns: nsCore, prefix: "Iptc4xmpCore", local: l, kind: .simple) }
        func contact(_ l: String) -> Prop { return Prop(ns: nsCore, prefix: "Iptc4xmpCore", local: l, kind: .simple, parent: contactInfo) }
        func lc(_ l: String) -> Prop { return Prop(ns: nsExt, prefix: "Iptc4xmpExt", local: l, kind: .simple, parent: locationCreated) }
        switch f {
        case .caption: return Prop(ns: nsDC, prefix: "dc", local: "description", kind: .alt)
        case .title: return Prop(ns: nsDC, prefix: "dc", local: "title", kind: .alt)
        case .copyright: return Prop(ns: nsDC, prefix: "dc", local: "rights", kind: .alt)
        case .keywords: return Prop(ns: nsDC, prefix: "dc", local: "subject", kind: .bag)
        case .creator: return Prop(ns: nsDC, prefix: "dc", local: "creator", kind: .seq)
        case .headline: return ps("Headline")
        case .credit: return ps("Credit")
        case .city: return ps("City")
        case .state: return ps("State")
        case .country: return ps("Country")
        case .instructions: return ps("Instructions")
        case .source: return ps("Source")
        case .jobID: return ps("TransmissionReference")
        case .category: return ps("Category")
        case .suppCategories: return ps("SupplementalCategories", .bag)
        case .captionWriter: return ps("CaptionWriter")
        case .dateCreated: return ps("DateCreated")
        case .location: return core("Location")
        case .countryCode: return core("CountryCode")
        case .event: return Prop(ns: nsExt, prefix: "Iptc4xmpExt", local: "Event", kind: .alt)
        case .personsShown: return Prop(ns: nsExt, prefix: "Iptc4xmpExt", local: "PersonInImage", kind: .bag)
        case .featuredOrg: return Prop(ns: nsExt, prefix: "Iptc4xmpExt", local: "OrganisationInImageName", kind: .bag)
        case .copyrightURL: return Prop(ns: nsRights, prefix: "xmpRights", local: "WebStatement", kind: .simple)
        case .copyrightMarked: return Prop(ns: nsRights, prefix: "xmpRights", local: "Marked", kind: .simple)
        case .usageTerms: return Prop(ns: nsRights, prefix: "xmpRights", local: "UsageTerms", kind: .alt)
        case .contactAddress: return contact("CiAdrExtadr")
        case .contactCity: return contact("CiAdrCity")
        case .contactState: return contact("CiAdrRegion")
        case .contactZip: return contact("CiAdrPcode")
        case .contactCountry: return contact("CiAdrCtry")
        case .contactPhone: return contact("CiTelWork")
        case .contactEmail: return contact("CiEmailWork")
        case .lcSublocation: return lc("Sublocation")
        case .lcCity: return lc("City")
        case .lcState: return lc("ProvinceState")
        case .lcCountry: return lc("CountryName")
        }
    }
    static let rating = Prop(ns: "http://ns.adobe.com/xap/1.0/", prefix: "xmp", local: "Rating", kind: .simple)
    static let colorClass = Prop(ns: "http://ns.camerabits.com/photomechanic/1.0/", prefix: "photomechanic", local: "ColorClass", kind: .simple)

    static let packetID = "W5M0MpCehiHzreSzNTczkc9d"

    /// A new, empty packet (with room to grow).
    static func emptyPacket() -> String {
        return "<?xpacket begin='\u{FEFF}' id='\(packetID)'?>\n<x:xmpmeta xmlns:x='adobe:ns:meta/'>\n<rdf:RDF xmlns:rdf='\(rdfNS)'>\n<rdf:Description rdf:about=''/>\n</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>"
    }

    // MARK: Names and scopes (0.18.13: each scope worked out once - 20x faster than 0.18.11)

    typealias Scope = [String: String]

    static func extend(_ sc: Scope, _ e: XElement) -> Scope {
        var m = sc
        for a in e.attrs where a.name.hasPrefix("xmlns:") { m[String(a.name.dropFirst(6))] = MiniXML.unescape(a.raw) }
        return m
    }
    static func split(_ n: String) -> (String, String) {
        if let c = n.index(of: ":") { return (String(n[..<c]), String(n[n.index(after: c)...])) }
        return ("", n)
    }
    static func qname(_ n: String, _ sc: Scope) -> (ns: String, local: String) {
        let (p, l) = split(n)
        return (sc[p] ?? "", l)
    }
    static func key(_ ns: String, _ local: String) -> String { return ns + "|" + local }
    /// An attribute that is a property (not a namespace declaration, xml:lang, or rdf:about etc.).
    static func isPropAttr(_ name: String, _ sc: Scope) -> Bool {
        if name.hasPrefix("xmlns") || name.hasPrefix("xml:") { return false }
        return qname(name, sc).ns != rdfNS
    }
    static func text(_ e: XElement) -> String {
        var o = ""
        for c in e.children {
            if case .text(let t) = c { o += MiniXML.unescape(t) }
            else if case .other(let t) = c, t.hasPrefix("<![CDATA[") { o += String(t.dropFirst(9).dropLast(3)) }
        }
        return o
    }
    static func hasText(_ e: XElement) -> Bool {
        return e.children.contains { if case .text(let t) = $0 { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return false }
    }
    static func escapeAttr(_ s: String) -> String {
        return MiniXML.escape(s).replacingOccurrences(of: "\n", with: "&#xA;").replacingOccurrences(of: "\r", with: "&#xD;").replacingOccurrences(of: "\t", with: "&#x9;")
    }

    /// rdf:RDF (and its scope).
    static func findRDF(_ nodes: [XNode], _ sc: Scope = [:]) -> (XElement, Scope)? {
        for n in nodes {
            guard case .element(let e) = n else { continue }
            let s2 = extend(sc, e)
            let q = qname(e.name, s2)
            if q.local == "RDF" && q.ns == rdfNS { return (e, s2) }
            if let r = findRDF(e.children, s2) { return r }
        }
        return nil
    }
    static func isXMPMeta(_ nodes: [XNode]) -> Bool {
        for n in nodes { if case .element(let e) = n { if split(e.name).1 == "xmpmeta" || isXMPMeta(e.children) { return true } } }
        return false
    }

    /// One occurrence of a property in a Description.
    enum Occ { case attr(String); case element(XElement, Scope) }

    /// Every property of every top-level Description, by namespace|name.
    static func index(_ rdf: XElement, _ rs: Scope) -> (descs: [(XElement, Scope)], props: [String: [Occ]]) {
        var descs: [(XElement, Scope)] = []
        var props: [String: [Occ]] = [:]
        for d in rdf.elements {
            let sd = extend(rs, d)
            let q = qname(d.name, sd)
            guard q.local == "Description" && q.ns == rdfNS else { continue }
            descs.append((d, sd))
            for a in d.attrs where isPropAttr(a.name, sd) {
                let qa = qname(a.name, sd)
                props[key(qa.ns, qa.local), default: []].append(.attr(a.raw))
            }
            for e in d.elements {
                let se = extend(sd, e)
                let qe = qname(e.name, se)
                props[key(qe.ns, qe.local), default: []].append(.element(e, se))
            }
        }
        return (descs, props)
    }

    /// Where a structure's fields are: the element itself (attributes, or child elements with
    /// rdf:parseType="Resource"), or an rdf:Description inside it. For a list (Location Created): its one entry.
    enum Holder { case found(XElement, Scope, resource: Bool); case emptyBag(XElement); case unknown }

    static func holder(_ e: XElement, _ se: Scope, inBag: Bool) -> Holder {
        if inBag {
            if e.attrs.contains(where: { isPropAttr($0.name, se) }) || hasText(e) { return .unknown }
            let els = e.elements
            guard els.count == 1 else { return .unknown }
            let sb = extend(se, els[0])
            let qb = qname(els[0].name, sb)
            guard qb.ns == rdfNS && (qb.local == "Bag" || qb.local == "Seq"), !hasText(els[0]) else { return .unknown }
            let lis = els[0].elements
            if lis.isEmpty { return .emptyBag(els[0]) }
            guard lis.count == 1 else { return .unknown }     // several places: ExifTool decides
            return structNode(lis[0], extend(sb, lis[0]))
        }
        return structNode(e, se)
    }
    static func structNode(_ n: XElement, _ sn: Scope) -> Holder {
        if hasText(n) { return .unknown }
        if n.attrs.contains(where: { let q = qname($0.name, sn); return q.ns == rdfNS && q.local == "parseType" && MiniXML.unescape($0.raw) == "Resource" }) {
            return .found(n, sn, resource: true)
        }
        let els = n.elements
        if els.isEmpty { return .found(n, sn, resource: false) }
        if els.count == 1, !n.attrs.contains(where: { isPropAttr($0.name, sn) }) {
            let sd = extend(sn, els[0])
            let q = qname(els[0].name, sd)
            if q.ns == rdfNS && q.local == "Description" { return .found(els[0], sd, resource: false) }
        }
        return .unknown
    }
    /// A structure's fields: namespace|name -> values (nil = a field Find doesn't understand).
    static func fields(_ h: XElement, _ sh: Scope) -> [String: [String]]? {
        var out: [String: [String]] = [:]
        for a in h.attrs where isPropAttr(a.name, sh) {
            let q = qname(a.name, sh)
            out[key(q.ns, q.local), default: []].append(MiniXML.unescape(a.raw))
        }
        for e in h.elements {
            let se = extend(sh, e)
            let q = qname(e.name, se)
            if !e.elements.isEmpty { out[key(q.ns, q.local), default: []].append("\u{0}"); continue }   // not a plain value
            out[key(q.ns, q.local), default: []].append(text(e))
        }
        return out
    }

    /// The values of one occurrence of a top-level property (nil = not a form Find reads).
    static func values(_ o: Occ) -> [String]? {
        switch o {
        case .attr(let raw): return [MiniXML.unescape(raw)]
        case .element(let e, let se):
            let els = e.elements
            if els.isEmpty { return [text(e)] }
            guard els.count == 1, !hasText(e) else { return nil }
            let sc = extend(se, els[0])
            let q = qname(els[0].name, sc)
            guard q.ns == rdfNS && ["Alt", "Bag", "Seq"].contains(q.local) else { return nil }
            var lis: [XElement] = []
            for li in els[0].elements {
                guard qname(li.name, extend(sc, li)) == (rdfNS, "li"), li.elements.isEmpty else { return nil }
                lis.append(li)
            }
            if q.local == "Alt" {
                if let d = lis.index(where: { $0.attrs.contains { $0.name == "xml:lang" && MiniXML.unescape($0.raw) == "x-default" } }) { return [text(lis[d])] }
                return lis.first.map { [text($0)] } ?? []
            }
            return lis.map { text($0) }
        }
    }

    /// Our properties from an XMP packet, keyed as ExifTool's JSON (-G1) keys them ("XMP-dc:Description",
    /// "XMP-iptcCore:CreatorCity", ...). nil = can't read it for sure (the caller asks ExifTool instead):
    /// not XMP, a property written twice or with other capitals, a form Find doesn't read.
    static func read(_ packet: String) -> [String: Any]? {
        guard let nodes = MiniXML.parse(packet) else { return nil }
        guard let (rdf, rs) = findRDF(nodes) else { return isXMPMeta(nodes) ? [:] : nil }
        let idx = index(rdf, rs)
        // Other capitals of our names (an old "dc:Creator" next to "dc:creator"): ExifTool decides.
        var lower: [String: Set<String>] = [:]
        for k in idx.props.keys { lower[k.lowercased(), default: []].insert(k) }
        func clean(_ ns: String, _ local: String) -> [Occ]? {
            let k = key(ns, local)
            if let variants = lower[k.lowercased()], variants.count > 1 || !variants.contains(k) { return variants.isEmpty ? [] : nil }
            let o = idx.props[k] ?? []
            return o.count > 1 ? nil : o
        }
        var out: [String: Any] = [:]
        var structs: [String: [String: [String]]] = [:]      // parent key -> its fields ([:] = none there)
        for p in [contactInfo, locationCreated] {
            guard let occ = clean(p.ns, p.local) else { return nil }
            guard let o = occ.first else { structs[key(p.ns, p.local)] = [:]; continue }
            guard case .element(let e, let se) = o else { return nil }
            switch holder(e, se, inBag: p.inBag) {
            case .unknown: return nil
            case .emptyBag: structs[key(p.ns, p.local)] = [:]
            case .found(let h, let sh, _):
                guard let f = fields(h, sh) else { return nil }
                structs[key(p.ns, p.local)] = f
            }
        }
        for f in MetaField.all {
            let p = prop(f)
            var vals: [String]
            if let par = p.parent {
                let fs = structs[key(par.ns, par.local)] ?? [:]
                if fs.keys.contains(where: { $0.lowercased() == key(p.ns, p.local).lowercased() && $0 != key(p.ns, p.local) }) { return nil }
                guard let v = fs[key(p.ns, p.local)] else { continue }
                guard v.count == 1, v[0] != "\u{0}" else { return nil }
                vals = v
            } else {
                guard let occ = clean(p.ns, p.local) else { return nil }
                guard let o = occ.first else { continue }
                guard let v = values(o) else { return nil }
                vals = v
            }
            if f == .dateCreated || f == .copyrightMarked { vals = vals.map { f.canonical($0) } }
            if f.isList { out[f.xmp] = vals as Any } else if let v = vals.first { out[f.xmp] = v as Any }
        }
        for (p, k) in [(rating, "XMP-xmp:Rating"), (colorClass, "XMP-photomech:ColorClass")] {
            guard let occ = clean(p.ns, p.local) else { return nil }
            if let o = occ.first {
                guard let v = values(o) else { return nil }
                if let first = v.first { out[k] = first }
            }
        }
        return out
    }

    /// `packet` with the given properties set (values) or removed (empty values). nil = can't edit it.
    /// `sizeTo`: the result padded with spaces to exactly this many UTF-8 bytes (nil if it can't fit);
    /// nil: padded with about 2 KB to grow into later.
    static func edit(_ packet: String?, _ changes: [(Prop, [String])], sizeTo: Int? = nil) -> Data? {
        let text = packet ?? emptyPacket()
        // 0.18.11: a packet Find can't read unambiguously is not changed by Find (ExifTool does it).
        if packet != nil && read(text) == nil { return nil }
        guard var nodes = MiniXML.parse(text) else { return nil }
        guard let (R, rs) = findRDF(nodes) else { return nil }
        var idx = index(R, rs)
        let rdfPrefix = split(R.name).0
        if idx.descs.isEmpty {
            let d = XElement(name: rdfPrefix + ":Description", attrs: [(rdfPrefix + ":about", "")])
            R.children.append(.element(d))
            idx = index(R, rs)
        }
        let first = idx.descs[0].0
        /// The prefix for `ns` where `node` is (declared on `node` if needed).
        func prefix(for ns: String, preferred: String, on node: XElement, scope sc: inout Scope) -> String {
            if let p = sc.first(where: { $0.value == ns })?.key, !p.isEmpty { return p }
            var p = preferred
            if sc[p] != nil {
                var k = 1
                while sc["ns\(k)"] != nil { k += 1 }
                p = "ns\(k)"
            }
            node.attrs.append(("xmlns:" + p, MiniXML.escape(ns)))
            sc[p] = ns
            return p
        }
        var firstScope = idx.descs[0].1
        let top = changes.filter { $0.0.parent == nil }
        // Top-level properties: removed everywhere (attribute or element form), then added to the first Description.
        let removeKeys = Set(top.map { key($0.0.ns, $0.0.local) })
        if !removeKeys.isEmpty {
            for (d, sd) in idx.descs {
                d.attrs = d.attrs.filter { a in
                    guard isPropAttr(a.name, sd) else { return true }
                    let q = qname(a.name, sd)
                    return !removeKeys.contains(key(q.ns, q.local))
                }
                d.children = d.children.filter { n in
                    guard case .element(let e) = n else { return true }
                    let q = qname(e.name, extend(sd, e))
                    return !removeKeys.contains(key(q.ns, q.local))
                }
            }
        }
        for (p, values) in top {
            let vals = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if vals.isEmpty { continue }
            let pre = prefix(for: p.ns, preferred: p.prefix, on: first, scope: &firstScope)
            let r = rdfPrefix
            let el = XElement(name: pre + ":" + p.local)
            switch p.kind {
            case .simple:
                el.children = [.text(MiniXML.escape(vals[0]))]
            case .alt:
                let li = XElement(name: r + ":li", attrs: [("xml:lang", "x-default")], children: [.text(MiniXML.escape(vals[0]))])
                el.children = [.element(XElement(name: r + ":Alt", children: [.element(li)]))]
            case .bag, .seq:
                let lis = vals.map { XNode.element(XElement(name: r + ":li", children: [.text(MiniXML.escape($0))])) }
                el.children = [.element(XElement(name: r + (p.kind == .bag ? ":Bag" : ":Seq"), children: lis))]
            }
            first.children.append(.text("\n"))
            first.children.append(.element(el))
        }
        // Structure fields (0.18.13): changed where the structure is; the structure made when it isn't there.
        for par in [contactInfo, locationCreated] {
            let mine = changes.filter { $0.0.parent.map { $0.ns == par.ns && $0.local == par.local } ?? false }
            if mine.isEmpty { continue }
            let anyValue = mine.contains { !$0.1.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.isEmpty }
            // The structure's element and the Description it is in.
            var found: (XElement, Scope, XElement)? = nil
            for (d, sd) in idx.descs {
                for e in d.elements {
                    let se = extend(sd, e)
                    let q = qname(e.name, se)
                    if q.ns == par.ns && q.local == par.local { found = (e, se, d) }
                }
            }
            var h: XElement
            var sh: Scope
            var resource = false
            var structEl: XElement
            var owner: XElement
            if let (e, se, d) = found {
                structEl = e
                owner = d
                switch holder(e, se, inBag: par.inBag) {
                case .unknown: return nil
                case .emptyBag(let bag):
                    if !anyValue { continue }
                    let li = XElement(name: rdfPrefix + ":li")
                    bag.children.append(.element(li))
                    h = li
                    sh = extend(extend(se, bag), li)
                case .found(let node, let sn, let res):
                    h = node
                    sh = sn
                    resource = res
                }
            } else {
                if !anyValue { continue }
                let pre = prefix(for: par.ns, preferred: par.prefix, on: first, scope: &firstScope)
                let e = XElement(name: pre + ":" + par.local)
                if par.inBag {
                    let li = XElement(name: rdfPrefix + ":li")
                    e.children = [.element(XElement(name: rdfPrefix + ":Bag", children: [.element(li)]))]
                    h = li
                } else {
                    h = e
                }
                first.children.append(.text("\n"))
                first.children.append(.element(e))
                structEl = e
                owner = first
                sh = firstScope
            }
            for (p, values) in mine {
                let k = key(p.ns, p.local)
                h.attrs = h.attrs.filter { a in
                    guard isPropAttr(a.name, sh) else { return true }
                    let q = qname(a.name, sh)
                    return key(q.ns, q.local) != k
                }
                h.children = h.children.filter { n in
                    guard case .element(let e) = n else { return true }
                    let q = qname(e.name, extend(sh, e))
                    return key(q.ns, q.local) != k
                }
                let v = values.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if v.isEmpty { continue }
                let pre = prefix(for: p.ns, preferred: p.prefix, on: h, scope: &sh)
                if resource {
                    h.children.append(.text("\n"))
                    h.children.append(.element(XElement(name: pre + ":" + p.local, children: [.text(MiniXML.escape(v))])))
                } else {
                    h.attrs.append((pre + ":" + p.local, escapeAttr(v)))
                }
            }
            // A structure left with no fields at all is taken out (as ExifTool does).
            let empty = !h.attrs.contains(where: { isPropAttr($0.name, sh) }) && h.elements.isEmpty
            if empty && (h === structEl || par.inBag) {
                owner.children = owner.children.filter { if case .element(let x) = $0 { return x !== structEl }; return true }
            }
        }
        // Padding: the whitespace just before the closing <?xpacket end=...?>.
        var endPI: XNode? = nil
        if let last = nodes.last, case .other(let t) = last, t.hasPrefix("<?xpacket end") { endPI = last; nodes.removeLast() }
        while let last = nodes.last, case .text(let t) = last, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { nodes.removeLast() }
        let body = MiniXML.serialize(nodes)
        let tail = endPI.map { if case .other(let t) = $0 { return t }; return "" } ?? ""
        let bodyBytes = body.utf8.count + 1 + tail.utf8.count
        var pad: Int
        if let want = sizeTo {
            pad = want - bodyBytes
            if pad < 0 { return nil }
        } else {
            pad = 2048
        }
        // Padding as lines of spaces (as the XMP specification recommends).
        var padding = "\n"
        var left = pad
        while left > 0 {
            let n = min(left, 100)
            if n == 1 { padding += " " } else { padding += String(repeating: " ", count: n - 1) + "\n" }
            left -= n
        }
        let out = body + padding + tail
        guard let d = out.data(using: .utf8) else { return nil }
        if let want = sizeTo, d.count != want { return nil }
        return d
    }
}

// MARK: - IPTC (IIM): datasets 0x1C record dataset length data

enum IIMBlock {
    struct DS { var record: UInt8; var dataset: UInt8; var data: Data }

    static func dataset(_ f: MetaField) -> UInt8? {
        switch f {
        case .title: return 5
        case .keywords: return 25
        case .instructions: return 40
        case .creator: return 80
        case .city: return 90
        case .location: return 92
        case .state: return 95
        case .country: return 101
        case .jobID: return 103
        case .headline: return 105
        case .credit: return 110
        case .source: return 115
        case .copyright: return 116
        case .caption: return 120
        case .category: return 15
        case .suppCategories: return 20
        case .dateCreated: return 55
        case .countryCode: return 100
        case .captionWriter: return 122
        default: return nil
        }
    }

    static func parse(_ d: Data) -> [DS]? {
        var out: [DS] = []
        let b = [UInt8](d)
        var i = 0
        while i < b.count {
            if b[i] == 0 { // padding at the end (zeros) is allowed
                if !b[i...].contains(where: { $0 != 0 }) { break }
                return nil
            }
            guard b[i] == 0x1C, i + 5 <= b.count else { return nil }
            var len = Int(b[i + 3]) << 8 | Int(b[i + 4])
            var start = i + 5
            if len & 0x8000 != 0 {          // extended length
                let n = len & 0x7FFF
                guard n <= 4, start + n <= b.count else { return nil }
                len = 0
                for k in 0..<n { len = len << 8 | Int(b[start + k]) }
                start += n
            }
            guard start + len <= b.count else { return nil }
            out.append(DS(record: b[i + 1], dataset: b[i + 2], data: Data(b[start..<(start + len)])))
            i = start + len
        }
        return out
    }

    static func serialize(_ ds: [DS]) -> Data {
        var o = Data()
        for x in ds {
            o.append(contentsOf: [0x1C, x.record, x.dataset])
            if x.data.count < 0x8000 {
                o.append(contentsOf: [UInt8(x.data.count >> 8), UInt8(x.data.count & 0xFF)])
            } else {
                let n = x.data.count
                o.append(contentsOf: [0x80, 0x04, UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            }
            o.append(x.data)
        }
        return o
    }

    /// The block with our fields replaced (UTF-8, declared in 1:90). nil = can't do it safely
    /// (e.g. existing text in another character set).
    static func edit(_ old: Data?, _ changes: [(MetaField, [String])]) -> Data? {
        var ds = old.flatMap { parse($0) } ?? []
        if old != nil && old!.count > 0 && ds.isEmpty { return nil }
        let utf8Mark = Data([0x1B, 0x25, 0x47])
        let hasUTF8 = ds.contains { $0.record == 1 && $0.dataset == 90 && $0.data == utf8Mark }
        if !hasUTF8 {
            // Text in another character set would be misread once UTF-8 is declared: only plain ASCII is safe.
            for x in ds where x.record == 2 && x.data.contains(where: { $0 >= 0x80 }) { return nil }
            ds = ds.filter { !($0.record == 1 && $0.dataset == 90) }
            ds.append(DS(record: 1, dataset: 90, data: utf8Mark))
        }
        if !ds.contains(where: { $0.record == 2 && $0.dataset == 0 }) {
            ds.append(DS(record: 2, dataset: 0, data: Data([0x00, 0x04])))
        }
        for (f, values) in changes {
            guard let n = dataset(f) else { continue }
            ds = ds.filter { !($0.record == 2 && $0.dataset == n) }
            for v0 in values.map({ f.canonical($0) }).filter({ !$0.isEmpty }) {
                var v = v0
                if f == .dateCreated {
                    // IPTC holds the date only, as CCYYMMDD (0.18.13).
                    let digits = String(v.prefix(10).unicodeScalars.filter { $0 >= "0" && $0 <= "9" }.map { Character($0) })
                    guard digits.count == 8 else { return nil }
                    v = digits
                }
                // Cut to the field's size, as ExifTool does (0.18.13).
                ds.append(DS(record: 2, dataset: n, data: Data(MetaPlan.iptcCut(v, f.iptcMaxBytes).utf8)))
            }
        }
        // Records in order, datasets in order (repeated ones keep their order).
        let indexed = ds.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            if a.1.record != b.1.record { return a.1.record < b.1.record }
            if a.1.dataset != b.1.dataset { return a.1.dataset < b.1.dataset }
            return a.0 < b.0
        }.map { $0.1 }
        return serialize(sorted)
    }
}

/// A file read only where looked at. 0.18.15: mapped again (0.18.14 read it in 64 KB pieces with plain
/// reads: on the user's share each piece was a slow round trip - planning took 10x longer; the mapped
/// file is paged in by macOS with read-ahead). `failed`: a look outside the file (nothing worked out
/// from such bytes is used).
final class FileBytes {
    private let d: Data
    let size: Int
    private(set) var failed = false

    init?(path: String) {
        guard let m = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        d = m
        size = m.count
    }

    /// Exactly the bytes of `r` (zeros and `failed` if outside the file).
    func read(_ r: Range<Int>) -> [UInt8] {
        if r.isEmpty { return [] }
        guard r.lowerBound >= 0, r.upperBound <= size else { failed = true; return [UInt8](repeating: 0, count: r.count) }
        return [UInt8](d[(d.startIndex + r.lowerBound)..<(d.startIndex + r.upperBound)])
    }
    func byte(_ i: Int) -> UInt8 {
        guard i >= 0, i < size else { failed = true; return 0 }
        return d[d.startIndex + i]
    }
}

/// Bytes of a file (or of data in memory), read only where looked at (a 60 MB RAW on a share isn't loaded whole).
struct ByteView {
    private let d: Data?
    private let f: FileBytes?
    init(_ d: Data) { self.d = d; self.f = nil }
    init(file: FileBytes) { self.d = nil; self.f = file }
    var count: Int { return f?.size ?? d!.count }
    /// A read failed somewhere: nothing worked out from these bytes may be used.
    var failed: Bool { return f?.failed ?? false }
    subscript(i: Int) -> UInt8 {
        if let f = f { return f.byte(i) }
        return d![d!.startIndex + i]
    }
    subscript(r: Range<Int>) -> Data {
        if let f = f { return Data(f.read(r)) }
        return d!.subdata(in: (d!.startIndex + r.lowerBound)..<(d!.startIndex + r.upperBound))
    }
}

// MARK: - The plan

struct InPlacePlan {
    /// Phase 1: new blocks (inside the old blocks' space or past the old end of the file).
    var blocks: [(offset: Int64, data: Data)] = []
    /// Phase 2: directory entries / pointers (small), written after phase 1 is safely on disk.
    var pointers: [(offset: Int64, data: Data)] = []
    /// The file's length before; the bytes each write will cover before (for putting back).
    var originalLength: Int64 = 0
    var saved: [(offset: Int64, data: Data)] = []
    var newLength: Int64 = 0
    var summary = ""
}

/// What a picture should end up with (from the change and its current values).
struct InPlaceValues {
    var fields: [(MetaField, [String])] = []    // [] = remove
    var rating: Int? = nil                      // 0 = remove
    var colorClass: Int? = nil

    init(_ c: MetaChange, current rec: [String: Any]) {
        for f in MetaField.all {
            if let v = c.set[f] {
                let t = f.canonical(v)      // as ExifTool is given it
                fields.append((f, f.isList ? MetaPlan.listValues(v) : (t.isEmpty ? [] : [t])))
            } else if f == .keywords && !c.addKeywords.isEmpty {
                var cur = MetaPlan.listValues(MetaPlan.current(.keywords, in: rec))
                for k in c.addKeywords where !cur.contains(k) { cur.append(k) }
                fields.append((f, cur))
            }
        }
        rating = c.rating
        colorClass = c.colorClass
    }

    func xmpChanges() -> [(XMPEditor.Prop, [String])] {
        // 0.18.13: XMP dates are ISO 8601 (2026-11-26T10:30:00+01:00); Find keeps them as ExifTool shows them.
        var o = fields.map { f -> (XMPEditor.Prop, [String]) in
            if f.0 == .dateCreated {
                return (XMPEditor.prop(f.0), f.1.map { v in
                    var u = Array(v.unicodeScalars)
                    for k in 0..<min(10, u.count) where u[k] == ":" { u[k] = "-" }
                    if u.count > 10 && u[10] == " " { u[10] = "T" }
                    var r = ""
                    r.unicodeScalars.append(contentsOf: u)
                    return r
                })
            }
            return (XMPEditor.prop(f.0), f.1)
        }
        if let r = rating { o.append((XMPEditor.rating, r <= 0 ? [] : ["\(min(5, r))"])) }
        if let c = colorClass { o.append((XMPEditor.colorClass, c <= 0 ? [] : ["\(min(8, c))"])) }
        return o
    }
    func iptcChanges() -> [(MetaField, [String])] { return fields.filter { IIMBlock.dataset($0.0) != nil } }
}

enum InPlaceMeta {
    /// File types done in place (others: the normal rewrite).
    static let tiffTypes: Set<String> = ["nef", "nrw", "dng", "arw", "pef", "tif", "tiff"]

    /// 0.18.10 fast check: every written block reads back exactly, and the file is still well-formed
    /// (JPEG: its segments and picture data; TIFF: its first directory).
    static func readsBack(_ path: String, _ plan: InPlacePlan) -> Bool {
        // 0.18.14: only the written bytes and the file's structure are read (0.18.13 read every JPEG whole -
        // its picture data, which an in-place change never touches - and that was most of the time on a share).
        guard let fb = FileBytes(path: path), Int64(fb.size) == plan.newLength else { return false }
        for w in plan.blocks + plan.pointers {
            let a = Int(w.offset), e = a + w.data.count
            guard a >= 0, e <= fb.size, Data(fb.read(a..<e)) == w.data else { return false }
        }
        let b = ByteView(file: fb)
        if JPEGImageCheck.isJPEG(path) {
            // The marker segments up to the picture data are sound, and every write ended before it.
            guard let picture = JPEGImageCheck.pictureStart(b) else { return false }
            let lastWrite = (plan.blocks + plan.pointers).map { Int($0.offset) + $0.data.count }.max() ?? 0
            return lastWrite <= picture && !b.failed
        }
        // TIFF: the header points to a directory whose entries fit in the file.
        guard b.count >= 8 else { return false }
        let le = b[0] == 0x49
        func u16(_ o: Int) -> Int { return le ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ o: Int) -> Int { return le ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }
        let ifd = u32(4)
        guard ifd >= 8, ifd + 2 <= b.count else { return false }
        let n = u16(ifd)
        return n > 0 && ifd + 2 + n * 12 + 4 <= b.count && !b.failed
    }

    static func canTry(_ path: String) -> Bool {
        let e = Paths.fileExtension(path).lowercased()
        return tiffTypes.contains(e) || JPEGImageCheck.isJPEG(path)
    }

    /// Reads what's needed and plans the writes. `xmp` / `iptc`: which blocks to write.
    static func plan(path: String, values v: InPlaceValues, xmp: Bool, iptc: Bool) -> InPlacePlan? {
        guard let fb = FileBytes(path: path) else { return nil }
        let b = ByteView(file: fb)
        let p = JPEGImageCheck.isJPEG(path) ? planJPEG(b, v, xmp: xmp, iptc: iptc) : planTIFF(b, v, xmp: xmp, iptc: iptc)
        return b.failed ? nil : p          // a read failed: not planned from bytes that may be wrong
    }

    // MARK: TIFF

    private struct Entry { var tag: UInt16; var type: UInt16; var count: UInt32; var value: UInt32; var at: Int }

    private static func planTIFF(_ b: ByteView, _ v: InPlaceValues, xmp wantXMP: Bool, iptc wantIPTC: Bool) -> InPlacePlan? {
        guard b.count >= 16 else { return nil }
        let le: Bool
        if b[0] == 0x49 && b[1] == 0x49 { le = true } else if b[0] == 0x4D && b[1] == 0x4D { le = false } else { return nil }
        func u16(_ o: Int) -> UInt16 { return le ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
        func u32(_ o: Int) -> UInt32 {
            return le ? UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
                      : UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        func w16(_ x: UInt16) -> [UInt8] { return le ? [UInt8(x & 0xFF), UInt8(x >> 8)] : [UInt8(x >> 8), UInt8(x & 0xFF)] }
        func w32(_ x: UInt32) -> [UInt8] {
            return le ? [UInt8(x & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x >> 16 & 0xFF), UInt8(x >> 24)]
                      : [UInt8(x >> 24), UInt8(x >> 16 & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
        }
        guard u16(2) == 42 else { return nil }                         // plain TIFF only (not BigTIFF, ORF, RW2)
        let ifd0 = Int(u32(4))
        guard ifd0 >= 8, ifd0 + 2 <= b.count else { return nil }
        let n = Int(u16(ifd0))
        guard n > 0, n < 1000, ifd0 + 2 + n * 12 + 4 <= b.count else { return nil }
        var entries: [Entry] = []
        for k in 0..<n {
            let o = ifd0 + 2 + k * 12
            entries.append(Entry(tag: u16(o), type: u16(o + 2), count: u32(o + 4), value: u32(o + 8), at: o))
        }
        // Sorted directory (a broken one is left to ExifTool).
        for k in 1..<max(1, entries.count) where entries[k].tag <= entries[k - 1].tag { return nil }
        let nextIFD = u32(ifd0 + 2 + n * 12)
        func typeSize(_ t: UInt16) -> Int { switch t { case 1, 2, 6, 7: return 1; case 3, 8: return 2; case 4, 9, 11, 13: return 4; case 5, 10, 12: return 8; default: return 0 } }
        func block(_ e: Entry) -> (offset: Int, size: Int)? {
            let sz = typeSize(e.type) * Int(e.count)
            guard sz > 0 else { return nil }
            if sz <= 4 { return (e.at + 8, sz) }
            let off = Int(e.value)
            guard off >= 8, off + sz <= b.count else { return nil }
            return (off, sz)
        }
        var plan = InPlacePlan()
        plan.originalLength = Int64(b.count)
        var end = b.count
        var newEntries: [Entry] = []          // entries to add (directory moved)
        var patchedEntries: [(at: Int, bytes: [UInt8])] = []
        // The blocks to write: (tag, type, new data).
        var jobs: [(tag: UInt16, type: UInt16, data: Data)] = []
        if wantXMP {
            let old = entries.first { $0.tag == 700 }
            var packet: String? = nil
            if let e = old, let bl = block(e) {
                guard let s = String(data: Data(b[bl.offset..<(bl.offset + bl.size)]), encoding: .utf8) else { return nil }
                packet = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            // Same size first (fits where it was), else with room to grow.
            var data: Data? = nil
            if let e = old, let bl = block(e), bl.size > 4 { data = XMPEditor.edit(packet, v.xmpChanges(), sizeTo: bl.size) }
            if data == nil { data = XMPEditor.edit(packet, v.xmpChanges()) }
            guard let x = data else { return nil }
            jobs.append((700, old?.type ?? 1, x))
        }
        if wantIPTC {
            let old = entries.first { $0.tag == 33723 }
            var cur: Data? = nil
            if let e = old, let bl = block(e) { cur = Data(b[bl.offset..<(bl.offset + bl.size)]) }
            guard var x = IIMBlock.edit(cur, v.iptcChanges()) else { return nil }
            // Tag 33723 is often LONG (4-byte units): pad with zeros to a multiple of 4.
            let t = old?.type ?? 4
            if typeSize(t) == 4 { while x.count % 4 != 0 { x.append(0) } }
            guard typeSize(t) == 1 || typeSize(t) == 4 else { return nil }
            jobs.append((33723, t, x))
        }
        if jobs.isEmpty { return nil }
        func save(_ off: Int, _ len: Int) {
            // The bytes a write covers inside the old file (to put back if anything goes wrong).
            let e2 = min(b.count, off + len)
            if off < e2 { plan.saved.append((Int64(off), Data(b[off..<e2]))) }
        }
        for j in jobs {
            let unit = j.type == 4 ? 4 : 1
            let count = UInt32(j.data.count / unit)
            var offset: Int
            let existing = entries.first { $0.tag == j.tag }
            let bl = existing.flatMap { block($0) }
            if existing != nil && bl == nil { return nil }
            if let o = bl, o.size > 4, j.data.count <= o.size {
                offset = o.offset                                        // fits where the old one was
            } else if let o = bl, o.size > 4, o.offset + o.size == b.count, end == b.count {
                offset = o.offset                                        // the old one was the last thing in the file
                end = offset + j.data.count
            } else {
                offset = (end + 1) & ~1                                  // past the end, word-aligned
                end = offset + j.data.count
            }
            save(offset, j.data.count)
            plan.blocks.append((Int64(offset), j.data))
            if let e = existing {
                patchedEntries.append((e.at, w16(e.tag) + w16(e.type) + w32(count) + w32(UInt32(offset))))
            } else {
                newEntries.append(Entry(tag: j.tag, type: j.type, count: count, value: UInt32(offset), at: -1))
            }
        }
        if newEntries.isEmpty {
            for p in patchedEntries {
                plan.saved.append((Int64(p.at), Data(b[p.at..<(p.at + 12)])))
                plan.pointers.append((Int64(p.at), Data(p.bytes)))
            }
        } else {
            // A copy of the first directory with the new entries, at the end; then the header points to it.
            // Values of 4 bytes or less sit inside the entry and are copied with it; larger ones stay
            // where they are (their offsets are absolute).
            var all = entries
            for p in patchedEntries {
                if let k = all.index(where: { $0.at == p.at }) {
                    let ent = p.bytes
                    let cnt = le ? UInt32(ent[4]) | UInt32(ent[5]) << 8 | UInt32(ent[6]) << 16 | UInt32(ent[7]) << 24
                                 : UInt32(ent[4]) << 24 | UInt32(ent[5]) << 16 | UInt32(ent[6]) << 8 | UInt32(ent[7])
                    let off = le ? UInt32(ent[8]) | UInt32(ent[9]) << 8 | UInt32(ent[10]) << 16 | UInt32(ent[11]) << 24
                                 : UInt32(ent[8]) << 24 | UInt32(ent[9]) << 16 | UInt32(ent[10]) << 8 | UInt32(ent[11])
                    all[k].count = cnt
                    all[k].value = off
                    all[k].at = -2
                }
            }
            all += newEntries
            all.sort { $0.tag < $1.tag }
            var dir = [UInt8]()
            dir += w16(UInt16(all.count))
            for e in all {
                dir += w16(e.tag) + w16(e.type) + w32(e.count)
                if e.at >= 0 { dir += Array(b[(e.at + 8)..<(e.at + 12)]) } else { dir += w32(e.value) }
            }
            dir += w32(nextIFD)
            let dirAt = (end + 1) & ~1
            end = dirAt + dir.count
            plan.blocks.append((Int64(dirAt), Data(dir)))
            plan.saved.append((4, Data(b[4..<8])))
            plan.pointers.append((4, Data(w32(UInt32(dirAt)))))
        }
        guard end < Int(UInt32.max) else { return nil }
        plan.newLength = Int64(max(end, b.count))
        plan.summary = "TIFF in place: \(plan.blocks.map { "\($0.data.count) B at \($0.offset)" }.joined(separator: ", "))" + (newEntries.isEmpty ? "" : ", first directory moved")
        return plan
    }

    // MARK: JPEG

    private struct Seg { let marker: UInt8; let start: Int; let end: Int }   // start = the FF byte

    private static func planJPEG(_ b: ByteView, _ v: InPlaceValues, xmp wantXMP: Bool, iptc wantIPTC: Bool) -> InPlacePlan? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        let xmpSig = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
        let psSig = Array("Photoshop 3.0\0".utf8)
        // The marker segments before the picture data.
        var segs: [Seg] = []
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let m = b[i + 1]
            if m == 0xDA || m == 0xD9 { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { return nil }
            segs.append(Seg(marker: m, start: i, end: i + 2 + len))
            i += 2 + len
        }
        func body(_ s: Seg) -> Data { return b[(s.start + 4)..<s.end] }
        func isXMP(_ s: Seg) -> Bool { return s.marker == 0xE1 && s.end - s.start - 4 > xmpSig.count && Array(b[(s.start + 4)..<(s.start + 4 + xmpSig.count)]) == xmpSig }
        func isPS(_ s: Seg) -> Bool { return s.marker == 0xED && s.end - s.start - 4 > psSig.count && Array(b[(s.start + 4)..<(s.start + 4 + psSig.count)]) == psSig }
        let xmpSegs = segs.indices.filter { isXMP(segs[$0]) }
        let psSegs = segs.indices.filter { isPS(segs[$0]) }
        if xmpSegs.count > 1 || psSegs.count > 1 { return nil }      // extended XMP / split IRB: not here
        guard let xi = xmpSegs.first else { return nil }             // the XMP's room is what makes this work
        // New XMP packet text and new IPTC (if asked).
        let oldPacket = String(data: body(segs[xi]).subdata(in: xmpSig.count..<(segs[xi].end - segs[xi].start - 4)), encoding: .utf8)
        guard let packet = oldPacket else { return nil }
        var newPS: Data? = nil
        if wantIPTC && !v.iptcChanges().isEmpty {
            guard let pi = psSegs.first else { return nil }          // no IPTC block yet: the normal way
            guard let irb = rebuildIRB(body(segs[pi]).subdata(in: psSig.count..<(segs[pi].end - segs[pi].start - 4)), v.iptcChanges()) else { return nil }
            newPS = Data(psSig) + irb
            if newPS!.count + 2 > 65535 { return nil }
        }
        // The region from the first to the last of the two segments is rewritten with the same total size:
        // the XMP's padding takes up the difference. Segments in between move with it (only when none of
        // them is a multi-picture index, whose offsets would no longer match).
        let pi = newPS != nil ? psSegs.first! : nil
        let lo = min(xi, pi ?? xi), hi = max(xi, pi ?? xi)
        for k in lo...hi where k != xi && k != pi {
            let s = segs[k]
            if s.marker == 0xE2 && Array(b[(s.start + 4)..<min(s.end, s.start + 8)]) == Array("MPF\0".utf8) { return nil }
        }
        let regionStart = segs[lo].start, regionEnd = segs[hi].end
        var others = 0
        for k in lo...hi where k != xi { others += k == pi ? (4 + newPS!.count) : (segs[k].end - segs[k].start) }
        let xmpRoom = (regionEnd - regionStart) - others - 4 - xmpSig.count       // bytes for the packet itself
        guard xmpRoom > 0, xmpRoom + xmpSig.count + 2 <= 65535 else { return nil }
        guard let newXMP = XMPEditor.edit(packet, wantXMP ? v.xmpChanges() : [], sizeTo: xmpRoom) else { return nil }
        var region = Data()
        for k in lo...hi {
            if k == xi {
                let len = 2 + xmpSig.count + newXMP.count
                region.append(contentsOf: [0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)])
                region.append(contentsOf: xmpSig)
                region.append(newXMP)
            } else if k == pi {
                let len = 2 + newPS!.count
                region.append(contentsOf: [0xFF, 0xED, UInt8(len >> 8), UInt8(len & 0xFF)])
                region.append(newPS!)
            } else {
                region.append(b[segs[k].start..<segs[k].end])
            }
        }
        guard region.count == regionEnd - regionStart else { return nil }
        var plan = InPlacePlan()
        plan.originalLength = Int64(b.count)
        plan.newLength = Int64(b.count)
        // Only the bytes that differ are written (often just the XMP and IPTC parts).
        let old = b[regionStart..<regionEnd]
        var firstDiff = -1, lastDiff = -1
        old.withUnsafeBytes { (po: UnsafePointer<UInt8>) in
            region.withUnsafeBytes { (pn: UnsafePointer<UInt8>) in
                for k in 0..<region.count where po[k] != pn[k] {
                    if firstDiff < 0 { firstDiff = k }
                    lastDiff = k
                }
            }
        }
        if firstDiff < 0 { return nil }                               // nothing changes
        let ws = regionStart + firstDiff, we = regionStart + lastDiff + 1
        plan.saved.append((Int64(ws), b[ws..<we]))
        plan.blocks.append((Int64(ws), region.subdata(in: firstDiff..<(lastDiff + 1))))
        plan.summary = "JPEG in place: \(we - ws) B at \(ws)" + (lo != hi ? " (XMP room took up the IPTC's change)" : "")
        return plan
    }

    /// The Photoshop resources of APP13 with the IPTC (0x0404) replaced and its digest (0x0425) kept current.
    private static func rebuildIRB(_ d: Data, _ changes: [(MetaField, [String])]) -> Data? {
        let r = [UInt8](d)
        var out = Data()
        var k = 0
        var iim: Data? = nil
        var sawIIM = false
        var digestOffset: Int? = nil
        while k + 12 <= r.count {
            guard r[k] == 0x38, r[k + 1] == 0x42, r[k + 2] == 0x49, r[k + 3] == 0x4D else { return nil }   // "8BIM"
            let id = Int(r[k + 4]) << 8 | Int(r[k + 5])
            let nameLen = Int(r[k + 6])
            var p = k + 7 + nameLen
            if (1 + nameLen) % 2 == 1 { p += 1 }
            guard p + 4 <= r.count else { return nil }
            let sz = Int(r[p]) << 24 | Int(r[p + 1]) << 16 | Int(r[p + 2]) << 8 | Int(r[p + 3])
            let dataAt = p + 4
            guard dataAt + sz <= r.count else { return nil }
            let header = Data(r[k..<p])
            if id == 0x0404 {
                guard !sawIIM, let n = IIMBlock.edit(Data(r[dataAt..<(dataAt + sz)]), changes) else { return nil }
                sawIIM = true
                iim = n
                out.append(header)
                out.append(contentsOf: [UInt8(n.count >> 24 & 0xFF), UInt8(n.count >> 16 & 0xFF), UInt8(n.count >> 8 & 0xFF), UInt8(n.count & 0xFF)])
                out.append(n)
                if n.count % 2 == 1 { out.append(0) }
            } else {
                if id == 0x0425 && sz == 16 { digestOffset = out.count + (dataAt - k) }
                out.append(Data(r[k..<(dataAt + sz)]))
                if sz % 2 == 1 { out.append(0) }
            }
            k = dataAt + sz + (sz % 2)
        }
        if k < r.count && r[k...].contains(where: { $0 != 0 }) { return nil }
        guard sawIIM, let n = iim else { return nil }
        if let dg = digestOffset {
            // Kept current, or Photoshop and Bridge would treat the IPTC as out of date.
            out.replaceSubrange(dg..<(dg + 16), with: MD5.digest(n))
        }
        return out
    }
}

// MARK: - MD5 (for Photoshop's IPTC digest, resource 0x0425, kept current when the IPTC changes)

enum MD5 {
    static func digest(_ data: Data) -> Data {
        var s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        var K = [UInt32](repeating: 0, count: 64)
        for i in 0..<64 { K[i] = UInt32(truncatingIfNeeded: Int64(abs(sin(Double(i + 1))) * 4294967296.0)) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xFF)) }
        var M = [UInt32](repeating: 0, count: 16)
        var chunk = 0
        while chunk < msg.count {
            for i in 0..<16 {
                let o = chunk + i * 4
                M[i] = UInt32(msg[o]) | UInt32(msg[o + 1]) << 8 | UInt32(msg[o + 2]) << 16 | UInt32(msg[o + 3]) << 24
            }
            var A = a0, B = b0, C = c0, D = d0
            for i in 0..<64 {
                var F: UInt32
                var g: Int
                switch i {
                case 0..<16: F = (B & C) | (~B & D); g = i
                case 16..<32: F = (D & B) | (~D & C); g = (5 * i + 1) % 16
                case 32..<48: F = B ^ C ^ D; g = (3 * i + 5) % 16
                default: F = C ^ (B | ~D); g = (7 * i) % 16
                }
                F = F &+ A &+ K[i] &+ M[g]
                A = D; D = C; C = B
                B = B &+ ((F << s[i]) | (F >> (32 - s[i])))
            }
            a0 = a0 &+ A; b0 = b0 &+ B; c0 = c0 &+ C; d0 = d0 &+ D
            chunk += 64
        }
        var out = Data()
        for v in [a0, b0, c0, d0] { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        _ = s.count
        s = []
        return out
    }
}

// MARK: - 0.18.11 Find's own reader (the fast path: no ExifTool in the common case)

extension IIMBlock {
    /// Our fields from an IPTC block, keyed as ExifTool keys them ("IPTC:Caption-Abstract", ...).
    static func read(_ d: Data) -> [String: Any]? {
        guard let ds = parse(d) else { return nil }
        let utf8 = ds.contains { $0.record == 1 && $0.dataset == 90 && $0.data == Data([0x1B, 0x25, 0x47]) }
        func str(_ x: Data) -> String {
            if utf8, let s = String(data: x, encoding: .utf8) { return s }
            return String(data: x, encoding: .isoLatin1) ?? ""
        }
        var out: [String: Any] = [:]
        for f in MetaField.all {
            guard let n = dataset(f), let key = f.iptc else { continue }
            var vals = ds.filter { $0.record == 2 && $0.dataset == n }.map { str($0.data) }
            if vals.isEmpty { continue }
            if f == .dateCreated {
                // CCYYMMDD -> YYYY:MM:DD, as ExifTool shows it.
                vals = vals.map { v in
                    let u = Array(v.unicodeScalars)
                    guard u.count == 8 else { return v }
                    var o = ""
                    for (k, c) in u.enumerated() { if k == 4 || k == 6 { o += ":" }; o.unicodeScalars.append(c) }
                    return o
                }
            }
            out[key] = f.isList ? (vals as Any) : (vals[0] as Any)
        }
        return out
    }
}

enum NativeMeta {
    /// Kinds of file Find reads itself.
    static func canRead(_ path: String) -> Bool {
        let e = Paths.fileExtension(path).lowercased()
        return e == "xmp" || InPlaceMeta.canTry(path)
    }

    /// The picture's (or sidecar's) metadata, as ExifTool would give it for our fields. nil = ask ExifTool.
    static func read(_ path: String) -> [String: Any]? {
        if Paths.fileExtension(path).lowercased() == "xmp" {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            if d.isEmpty { return [:] }
            guard let s = String(data: d, encoding: .utf8) else { return nil }
            return XMPEditor.read(s)
        }
        // 0.18.14: only the pieces holding the metadata are read.
        guard let fb = FileBytes(path: path) else { return nil }
        let bv = ByteView(file: fb)
        guard let blocks = InPlaceMeta.metadataBlocks(bv, isJPEG: JPEGImageCheck.isJPEG(path)), !bv.failed else { return nil }
        var out: [String: Any] = [:]
        if let x = blocks.xmp {
            guard let s = String(data: x, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")), let r = XMPEditor.read(s) else { return nil }
            for (k, v) in r { out[k] = v }
        }
        if let i = blocks.iptc {
            guard let r = IIMBlock.read(i) else { return nil }
            for (k, v) in r { out[k] = v }
        }
        return out
    }
}

extension InPlaceMeta {
    /// The XMP packet and IPTC block of a JPEG or TIFF-type file (each nil when there is none).
    /// nil = the file's structure isn't one Find reads itself.
    static func metadataBlocks(_ b: ByteView, isJPEG: Bool) -> (xmp: Data?, iptc: Data?)? {
        if isJPEG {
            guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
            let xmpSig = Array("http://ns.adobe.com/xap/1.0/\0".utf8), psSig = Array("Photoshop 3.0\0".utf8)
            let extSig = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
            var x: Data? = nil, ip: Data? = nil
            var photoshopSegments = 0
            var i = 2
            while i + 4 <= b.count {
                guard b[i] == 0xFF else { return nil }
                let m = b[i + 1]
                if m == 0xDA || m == 0xD9 { break }
                let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
                guard len >= 2, i + 2 + len <= b.count else { return nil }
                let body = i + 4, end = i + 2 + len
                if m == 0xE1 && end - body > xmpSig.count && Array(b[body..<(body + xmpSig.count)]) == xmpSig {
                    if x != nil { return nil }
                    x = b[(body + xmpSig.count)..<end]
                }
                // Extended XMP (spread over several segments): ExifTool joins it; Find leaves such files to it.
                if m == 0xE1 && end - body > extSig.count && Array(b[body..<(body + extSig.count)]) == extSig { return nil }
                if m == 0xED && end - body > psSig.count && Array(b[body..<(body + psSig.count)]) == psSig {
                    photoshopSegments += 1
                    if photoshopSegments > 1 { return nil }
                    let r = [UInt8](b[(body + psSig.count)..<end])
                    var k = 0
                    while k + 12 <= r.count, r[k] == 0x38, r[k + 1] == 0x42, r[k + 2] == 0x49, r[k + 3] == 0x4D {
                        let id = Int(r[k + 4]) << 8 | Int(r[k + 5])
                        let nameLen = Int(r[k + 6])
                        var p = k + 7 + nameLen
                        if (1 + nameLen) % 2 == 1 { p += 1 }
                        guard p + 4 <= r.count else { return nil }
                        let sz = Int(r[p]) << 24 | Int(r[p + 1]) << 16 | Int(r[p + 2]) << 8 | Int(r[p + 3])
                        guard p + 4 + sz <= r.count else { return nil }
                        if id == 0x0404 { if ip != nil { return nil }; ip = Data(r[(p + 4)..<(p + 4 + sz)]) }
                        k = p + 4 + sz + (sz % 2)
                    }
                }
                i = end
            }
            return (x, ip)
        }
        guard b.count >= 16 else { return nil }
        let le: Bool
        if b[0] == 0x49 && b[1] == 0x49 { le = true } else if b[0] == 0x4D && b[1] == 0x4D { le = false } else { return nil }
        func u16(_ o: Int) -> Int { return le ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ o: Int) -> Int { return le ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }
        guard u16(2) == 42 else { return nil }
        let ifd = u32(4)
        guard ifd >= 8, ifd + 2 <= b.count else { return nil }
        let n = u16(ifd)
        guard n > 0, n < 1000, ifd + 2 + n * 12 + 4 <= b.count else { return nil }
        var x: Data? = nil, ip: Data? = nil
        for k in 0..<n {
            let o = ifd + 2 + k * 12
            let tag = u16(o), type = u16(o + 2), count = u32(o + 4)
            guard tag == 700 || tag == 33723 else { continue }
            let unit = type == 4 ? 4 : (type == 1 || type == 7 ? 1 : 0)
            guard unit > 0 else { return nil }
            let size = unit * count
            let at = size <= 4 ? o + 8 : u32(o + 8)
            guard at >= 0, at + size <= b.count else { return nil }
            if tag == 700 { x = b[at..<(at + size)] } else { ip = b[at..<(at + size)] }
        }
        return (x, ip)
    }
}
