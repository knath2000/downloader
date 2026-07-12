import Foundation

enum SeedboxRemoteFileClientFactory {
    static func make(
        transferMode: String,
        remoteName: String,
        remotePath: String,
        webdavURL: String,
        webdavUser: String,
        webdavPassword: String
    ) throws -> RemoteFileClient {
        if transferMode == "webdav" {
            let trimmedURL = webdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let baseURL = URLTrustPolicy.validated(trimmedURL), baseURL.scheme?.lowercased() == "https" else {
                throw RemoteFileClientError.notConfigured("Seedbox WebDAV URL is not configured.")
            }

            return WebDAVRemoteFileClient(
                baseURL: baseURL,
                rootPath: remotePath,
                user: webdavUser,
                password: webdavPassword,
                allowSelfSigned: UserDefaults.standard.bool(forKey: "seedboxWebdavAllowSelfSigned")
            )
        }

        let trimmedRemote = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemote.isEmpty else {
            throw RemoteFileClientError.notConfigured("Seedbox rclone remote name is not configured.")
        }

        guard let rclone = ToolLocator.find("rclone") else {
            throw RemoteFileClientError.notAvailable("rclone is not installed. Install with: brew install rclone")
        }

        guard SeedboxManager.isRcloneConfigured(remoteName: trimmedRemote) else {
            throw RemoteFileClientError.notConfigured("Seedbox rclone remote '\(trimmedRemote)' is not configured.")
        }

        return RcloneRemoteFileClient(
            provider: .seedbox,
            remoteName: trimmedRemote,
            rootPath: remotePath,
            rclone: rclone
        )
    }
}
