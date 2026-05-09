import Foundation

struct WebDAVListEntry: Equatable {
    let href: String
    let displayName: String?
    let isCollection: Bool
    let contentLength: Int64?
    let lastModified: Date?
    let contentType: String?
}

final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
    private var entries: [WebDAVListEntry] = []

    private var currentElement = ""
    private var currentText = ""

    private var href = ""
    private var displayName: String?
    private var isCollection = false
    private var contentLength: Int64?
    private var lastModified: Date?
    private var contentType: String?

    static func parse(data: Data) throws -> [WebDAVListEntry] {
        let delegate = WebDAVMultiStatusParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            throw RemoteFileClientError.responseParsingFailed(
                parser.parserError?.localizedDescription ?? "Could not parse WebDAV response."
            )
        }

        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""

        if currentElement.hasSuffix("response") {
            href = ""
            displayName = nil
            isCollection = false
            contentLength = nil
            lastModified = nil
            contentType = nil
        }

        if currentElement.hasSuffix("collection") {
            isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if element.hasSuffix("href") {
            href = value
        } else if element.hasSuffix("displayname") {
            displayName = value.isEmpty ? nil : value
        } else if element.hasSuffix("getcontentlength") {
            contentLength = Int64(value)
        } else if element.hasSuffix("getlastmodified") {
            lastModified = Self.parseHTTPDate(value)
        } else if element.hasSuffix("getcontenttype") {
            contentType = value.isEmpty ? nil : value
        } else if element.hasSuffix("response") {
            guard !href.isEmpty else { return }
            entries.append(
                WebDAVListEntry(
                    href: href,
                    displayName: displayName,
                    isCollection: isCollection,
                    contentLength: contentLength,
                    lastModified: lastModified,
                    contentType: contentType
                )
            )
        }

        currentText = ""
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

final class WebDAVRemoteFileClient: RemoteFileClient {
    let provider: RemoteFileProviderID = .seedbox

    private let baseURL: URL
    private let rootPath: String
    private let user: String
    private let password: String

    init(baseURL: URL, rootPath: String, user: String, password: String) {
        self.baseURL = baseURL
        self.rootPath = RemotePath.normalizeDirectory(rootPath)
        self.user = user
        self.password = password
    }

    func list(path: String) async throws -> RemoteDirectoryListing {
        let url = urlForDirectory(uiPath: path)

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = 30
        request.setValue("1", forHTTPHeaderField: "Depth")
        setBasicAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)

        let entries = try WebDAVMultiStatusParser.parse(data: data)
        let currentPath = normalizedWebDAVPath(url.path)

        let items = entries.compactMap { entry -> RemoteFileItem? in
            let href = entry.href.removingPercentEncoding ?? entry.href
            let hrefURL = URL(string: href, relativeTo: baseURL)
            let hrefPath = hrefURL?.path.removingPercentEncoding ?? href
            let cleanHrefPath = normalizedWebDAVPath(hrefPath)

            guard cleanHrefPath != currentPath else { return nil }

            let fallbackName = cleanHrefPath.split(separator: "/").last.map(String.init) ?? ""
            let name = entry.displayName?.isEmpty == false ? entry.displayName! : fallbackName
            guard !name.isEmpty else { return nil }

            return RemoteFileItem(
                name: name,
                path: RemotePath.joining(directory: path, name: name),
                kind: entry.isCollection ? .folder : .file,
                size: entry.contentLength,
                modifiedAt: entry.lastModified,
                contentType: entry.contentType
            )
        }
        .sorted(by: RcloneRemoteFileParser.sortRemoteItems)

        return RemoteDirectoryListing(
            provider: .seedbox,
            path: RemotePath.normalizeDirectory(path),
            items: items,
            loadedAt: Date()
        )
    }

    func createFolder(named name: String, in directory: String) async throws {
        let folderPath = RemotePath.joining(directory: directory, name: name)
        let url = urlForPath(uiPath: folderPath, isDirectory: true)

        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        request.timeoutInterval = 30
        setBasicAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 405 {
            return
        }
        try validateHTTP(response)
    }

    func rename(itemAt path: String, to newName: String) async throws {
        let source = urlForPath(uiPath: path, isDirectory: false)
        let destinationPath = RemotePath.joining(directory: RemotePath.parent(of: path), name: newName)
        let destination = urlForPath(uiPath: destinationPath, isDirectory: false)

        var request = URLRequest(url: source)
        request.httpMethod = "MOVE"
        request.timeoutInterval = 120
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        setBasicAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
    }

    func move(itemAt path: String, kind: RemoteFileKind, toDirectory directory: String, newName: String?) async throws {
        let source = urlForPath(uiPath: path, isDirectory: kind == .folder)
        let targetName = newName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? newName!
            : RemotePath.basename(path)
        let destinationPath = RemotePath.joining(directory: directory, name: targetName)
        let destination = urlForPath(uiPath: destinationPath, isDirectory: kind == .folder)

        var request = URLRequest(url: source)
        request.httpMethod = "MOVE"
        request.timeoutInterval = 7200
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        setBasicAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
    }

    func copy(itemAt path: String, kind: RemoteFileKind, toDirectory directory: String, newName: String?) async throws {
        let source = urlForPath(uiPath: path, isDirectory: kind == .folder)
        let targetName = newName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? newName!
            : RemotePath.basename(path)
        let destinationPath = RemotePath.joining(directory: directory, name: targetName)
        let destination = urlForPath(uiPath: destinationPath, isDirectory: kind == .folder)

        var request = URLRequest(url: source)
        request.httpMethod = "COPY"
        request.timeoutInterval = 7200
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        if kind == .folder {
            request.setValue("infinity", forHTTPHeaderField: "Depth")
        }
        setBasicAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
    }

    func delete(itemAt path: String, kind: RemoteFileKind) async throws {
        let url = urlForPath(uiPath: path, isDirectory: kind == .folder)

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 120
        setBasicAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        let url = urlForPath(uiPath: path, isDirectory: false)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 7200
        setBasicAuth(&request)

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        try validateHTTP(response)

        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)
    }

    func uploadFile(from localURL: URL, to directory: String, remoteName remoteFileName: String?) async throws {
        let name = remoteFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? remoteFileName!
            : localURL.lastPathComponent

        let remotePath = RemotePath.joining(directory: directory, name: name)
        let url = urlForPath(uiPath: remotePath, isDirectory: false)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 7200
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        setBasicAuth(&request)

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: localURL)
        try validateHTTP(response)
    }

    func readTextFile(at path: String, maxBytes: Int64) async throws -> String {
        let url = urlForPath(uiPath: path, isDirectory: false)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        setBasicAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)

        guard Int64(data.count) <= maxBytes else {
            throw RemoteFileClientError.fileTooLargeForTextEdit(maxBytes: maxBytes)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteFileClientError.notTextEditable("File is not valid UTF-8 text.")
        }

        return text
    }

    func saveTextFile(_ text: String, to path: String) async throws {
        let data = Data(text.utf8)
        let url = urlForPath(uiPath: path, isDirectory: false)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        setBasicAuth(&request)

        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        try validateHTTP(response)
    }

    private func urlForDirectory(uiPath: String) -> URL {
        urlForPath(uiPath: uiPath, isDirectory: true)
    }

    private func urlForPath(uiPath: String, isDirectory: Bool) -> URL {
        var url = baseURL

        let root = RemotePath.normalizeDirectory(rootPath)
        let ui = RemotePath.normalizeDirectory(uiPath)
        let combined: String

        if root == "/" {
            combined = ui
        } else if ui == "/" {
            combined = root
        } else {
            combined = RemotePath.normalizeDirectory(root + "/" + String(ui.dropFirst()))
        }

        let parts = combined.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(part, isDirectory: isDirectory && index == parts.count - 1)
        }

        if isDirectory, parts.isEmpty, !url.absoluteString.hasSuffix("/") {
            url.appendPathComponent("", isDirectory: true)
        }

        return url
    }

    private func setBasicAuth(_ request: inout URLRequest) {
        guard !user.isEmpty || !password.isEmpty else { return }
        let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteFileClientError.httpFailed(http.statusCode)
        }
    }

    private func normalizedWebDAVPath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let normalized = RemotePath.normalizeDirectory(decoded)
        return normalized == "/" ? "/" : normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
