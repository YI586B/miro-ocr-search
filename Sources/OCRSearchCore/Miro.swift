import Foundation
import ImageIO

public enum MiroError: Error, CustomStringConvertible, LocalizedError {
    case http(Int, String), badResponse
    public var description: String {
        switch self {
        case .http(let c, let b): return "Miro API \(c): \(b)"
        case .badResponse: return "unexpected Miro response"
        }
    }
    // So callers using error.localizedDescription (the normal way to surface an error to a
    // user) get this description too, instead of Swift's generic "operation couldn't be
    // completed" fallback for errors that aren't NSError-bridged.
    public var errorDescription: String? { description }
}

/// Minimal Miro REST v2 client. Token comes from MIRO_TOKEN (a personal access token
/// with boards:read + boards:write scopes).
public struct MiroClient {
    let token: String
    public init(token: String) { self.token = token }
    let base = "https://api.miro.com/v2"

    private func send(_ req: URLRequest) throws -> [String: Any] {
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<4 {
            var out: (Data?, HTTPURLResponse?, Error?) = (nil, nil, nil)
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { d, r, e in out = (d, r as? HTTPURLResponse, e); sem.signal() }.resume()
            sem.wait()
            if let e = out.2 { throw e }
            guard let http = out.1 else { throw MiroError.badResponse }
            if http.statusCode == 429, attempt < 3 { Thread.sleep(forTimeInterval: 2 * Double(attempt + 1)); continue }
            let data = out.0 ?? Data()
            guard (200..<300).contains(http.statusCode) else {
                throw MiroError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        throw MiroError.badResponse
    }

    private func json(_ path: String, _ body: [String: Any]) throws -> [String: Any] {
        var r = URLRequest(url: URL(string: base + path)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try send(r)
    }

    /// Returns (board id, view link).
    public func createBoard(name: String) throws -> (id: String, link: String) {
        let r = try json("/boards", ["name": name])
        guard let id = r["id"] as? String else { throw MiroError.badResponse }
        return (id, r["viewLink"] as? String ?? "https://miro.com/app/board/\(id)/")
    }

    /// Uploads a local image file; x/y are the item's centre on the board.
    public func addImage(board: String, file: URL, x: Double, y: Double, width: Double) throws {
        let boundary = "ocrsearch-\(UUID().uuidString)"
        let meta: [String: Any] = [
            "title": file.lastPathComponent,
            "position": ["x": x, "y": y],
            "geometry": ["width": width],
        ]
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(try JSONSerialization.data(withJSONObject: meta))
        add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"resource\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(mime(file))\r\n\r\n")
        body.append(try Data(contentsOf: file))
        add("\r\n--\(boundary)--\r\n")
        var r = URLRequest(url: URL(string: "\(base)/boards/\(board)/images")!)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        _ = try send(r)
    }

    public func addSticky(board: String, text: String, x: Double, y: Double, width: Double) throws {
        let esc = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        _ = try json("/boards/\(board)/sticky_notes", [
            "data": ["content": esc, "shape": "rectangle"],
            "position": ["x": x, "y": y],
            "geometry": ["width": width],
        ])
    }

    private func mime(_ u: URL) -> String {
        switch u.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "webp": return "image/webp"
        default: return "application/octet-stream"   // HEIC: Miro may reject; convert to PNG first
        }
    }
}

/// Lays results out in a grid: image with its OCR snippet as a sticky note underneath.
/// Creates a new board unless `boardID` is given. Returns the board's view link.
public func exportToMiro(items: [(path: String, snippet: String)], token: String,
                         boardID: String?, boardName: String,
                         log: (String) -> Void = { print($0) }) throws -> String {
    let client = MiroClient(token: token)
    let board: String, link: String
    if let id = boardID { board = id; link = "https://miro.com/app/board/\(id)/" }
    else { (board, link) = try client.createBoard(name: boardName) }

    let cols = 4, cellW = 520.0, cellH = 820.0, maxW = 420.0, maxH = 480.0
    for (i, item) in items.enumerated() {
        let url = URL(fileURLWithPath: item.path)
        let cx = Double(i % cols) * cellW, top = Double(i / cols) * cellH
        var w = maxW, h = maxH
        if let s = imagePixelSize(at: url.path) {
            let sw = Double(s.width), sh = Double(s.height)
            let k = min(maxW / sw, maxH / sh); w = sw * k; h = sh * k
        }
        do {
            try client.addImage(board: board, file: url, x: cx, y: top + h / 2, width: w)
            if !item.snippet.isEmpty {
                try client.addSticky(board: board, text: item.snippet, x: cx, y: top + h + 160, width: 300)
            }
            log("exported \(url.lastPathComponent) (\(i + 1)/\(items.count))")
        } catch { log("failed   \(url.lastPathComponent): \(error)") }
    }
    return link
}
