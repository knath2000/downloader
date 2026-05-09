import Foundation

protocol RemoteFileClient {
    var provider: RemoteFileProviderID { get }

    func list(path: String) async throws -> RemoteDirectoryListing
    func createFolder(named name: String, in directory: String) async throws
    func rename(itemAt path: String, to newName: String) async throws
    func move(itemAt path: String, kind: RemoteFileKind, toDirectory directory: String, newName: String?) async throws
    func copy(itemAt path: String, kind: RemoteFileKind, toDirectory directory: String, newName: String?) async throws
    func delete(itemAt path: String, kind: RemoteFileKind) async throws
    func downloadFile(at path: String, to localURL: URL) async throws
    func uploadFile(from localURL: URL, to directory: String, remoteName: String?) async throws
    func readTextFile(at path: String, maxBytes: Int64) async throws -> String
    func saveTextFile(_ text: String, to path: String) async throws
}
