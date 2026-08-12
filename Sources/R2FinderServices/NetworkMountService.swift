// NetworkMountService.swift
// Mounting network shares (smb://, afp://, nfs://, WebDAV) from inside the
// app instead of handing the URL to Finder via NSWorkspace.open().
//
// NetFS is the same framework Finder uses: NetFSMountURLAsync goes through
// NetAuthAgent, so the user gets the standard authentication sheet and, for
// a bare server URL, the standard "select the volumes you want to mount"
// picker — without Finder ever coming to the front.

import Foundation
import NetFS

public enum NetworkMountError: Error {
    case invalidURL(String)
    case unsupportedScheme(String)
    /// The user dismissed the authentication or share-picker dialog.
    case cancelled
    case failed(status: Int32, message: String)

    public var message: String {
        switch self {
        case .invalidURL(let s):        return "La dirección '\(s)' no es válida."
        case .unsupportedScheme(let s): return "El protocolo '\(s)' no está soportado."
        case .cancelled:                return "Conexión cancelada."
        case .failed(_, let msg):       return msg
        }
    }
}

@MainActor
public enum NetworkMountService {

    /// URL schemes NetFS knows how to mount.
    public static let supportedSchemes = ["smb", "cifs", "afp", "nfs", "ftp", "http", "https"]

    /// Turn user input into a mountable URL: a bare host or IP ("nas",
    /// "192.168.1.10", "nas.local/media") is assumed to be SMB, which is what
    /// Finder's "Connect to Server" does too.
    public static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "smb://" + text }

        if let url = URL(string: text), url.scheme != nil, url.host != nil { return url }
        // Retry with percent-encoding for spaces and other literals that are
        // legal in a share name but not in a URL ("smb://nas/Mi Disco").
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
              let url = URL(string: encoded), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// Mount `url`, presenting the system authentication / share-picker UI
    /// when needed. `completion` runs on the main actor with the POSIX paths
    /// of everything that got mounted (usually one, more if the user picked
    /// several shares in the picker).
    public static func mount(_ url: URL,
                             completion: @escaping @MainActor (Result<[String], NetworkMountError>) -> Void) {
        guard let scheme = url.scheme?.lowercased() else {
            completion(.failure(.invalidURL(url.absoluteString)))
            return
        }
        guard supportedSchemes.contains(scheme) else {
            completion(.failure(.unsupportedScheme(scheme)))
            return
        }

        // AllowUI: show the same authentication sheet Finder shows. Without it
        // the mount fails outright whenever credentials are needed.
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI

        // AllowSubMounts lets "smb://host/share/subdir" mount the subdirectory;
        // SoftMount keeps I/O from hanging forever if the server disappears.
        let mountOptions = NSMutableDictionary()
        mountOptions[kNetFSAllowSubMountsKey] = true
        mountOptions[kNetFSSoftMountKey] = true

        // NetFS delivers the result through a plain C block, which can't carry
        // main-actor isolation; assumeIsolated below re-establishes it, which
        // is sound because we hand NetFS the main queue.
        let handler = completion

        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(
            url as CFURL, nil, nil, nil,
            openOptions as CFMutableDictionary,
            mountOptions as CFMutableDictionary,
            &requestID, DispatchQueue.main,
            { status, _, mountpoints in
                MainActor.assumeIsolated {
                    if status == 0 {
                        handler(.success((mountpoints as? [String]) ?? []))
                    } else {
                        handler(.failure(error(for: status)))
                    }
                }
            })

        // A non-zero return means the request never got off the ground; the
        // block is not called in that case.
        if status != 0 {
            completion(.failure(error(for: status)))
        }
    }

    /// Map a NetFS status to something worth putting in an alert.
    /// Positive values are errno, negative ones are OSStatus / NetAuth errors.
    private static func error(for status: Int32) -> NetworkMountError {
        switch status {
        case -128:  return .cancelled          // userCanceledErr
        case -5045: return .failed(status: status, message: "La contraseña ha caducado y debe cambiarse.")
        case -5046: return .failed(status: status, message: "La contraseña no cumple la política del servidor.")
        case -5996: return .failed(status: status, message: "El servidor no admite ninguna versión del protocolo compatible.")
        case -5997: return .failed(status: status, message: "El servidor no admite ningún método de autenticación compatible.")
        case -5998, -6003:
            return .failed(status: status, message: "El servidor no ofrece ningún recurso compartido.")
        case -5999: return .failed(status: status, message: "La cuenta tiene restricciones de acceso.")
        case -6004: return .failed(status: status, message: "El servidor no permite el acceso como invitado.")
        case -6602: return .failed(status: status, message: "No se pudo montar el recurso compartido.")
        case ..<0:  return .failed(status: status, message: "Error de conexión (\(status)).")
        default:
            let text = String(cString: strerror(status))
            return .failed(status: status, message: "\(text) (\(status)).")
        }
    }
}
