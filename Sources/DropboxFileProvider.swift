//
//  DropboxFileProvider.swift
//  FileProvider
//
//  Created by Amir Abbas Mousavian.
//  Copyright © 2016 Mousavian. Distributed under MIT license.
//

import Foundation

public struct FileProviderDropboxError: ErrorType, CustomStringConvertible {
    public let code: FileProviderHTTPErrorCode
    public let path: String
    
    public var description: String {
        return code.description
    }
}

public final class DropboxFileObject: FileObject {
    public let serverTime: NSDate?
    public let id: String?
    public let rev: String?
    
    public init(absoluteURL: NSURL, name: String, path: String, size: Int64, serverTime: NSDate?, createdDate: NSDate?, modifiedDate: NSDate?, fileType: FileType, isHidden: Bool, isReadOnly: Bool, id: String?, rev: String?) {
        self.serverTime = serverTime
        self.id = id
        self.rev = rev
        super.init(absoluteURL: absoluteURL, name: name, path: path, size: size, createdDate: createdDate, modifiedDate: modifiedDate, fileType: fileType, isHidden: isHidden, isReadOnly: isReadOnly)
    }
}

// Because this class uses NSURLSession, it's necessary to disable App Transport Security
// in case of using this class with unencrypted HTTP connection.

public class DropboxFileProvider: NSObject,  FileProviderBasic {
    public let type: String = "WebDAV"
    public let isPathRelative: Bool = true
    public let baseURL: NSURL?
    public var currentPath: String = ""
    public var dispatch_queue: dispatch_queue_t {
        willSet {
            assert(_session == nil, "It's not effective to change dispatch_queue property after session is initialized.")
        }
    }
    public weak var delegate: FileProviderDelegate?
    public let credential: NSURLCredential?
    
    private var _session: NSURLSession?
    private var session: NSURLSession {
        if _session == nil {
            let queue = NSOperationQueue()
            //queue.underlyingQueue = dispatch_queue
            _session = NSURLSession(configuration: NSURLSessionConfiguration.defaultSessionConfiguration(), delegate: self, delegateQueue: queue)
        }
        return _session!
    }
    
    public init? (baseURL: NSURL, credential: NSURLCredential?) {
        if  !["http", "https"].contains(baseURL.uw_scheme.lowercaseString) {
            return nil
        }
        self.baseURL = baseURL
        dispatch_queue = dispatch_queue_create("FileProvider.\(type)", DISPATCH_QUEUE_CONCURRENT)
        //let url = baseURL.uw_absoluteString
        self.credential = credential
    }
    
    deinit {
        _session?.invalidateAndCancel()
    }
    
    public func contentsOfDirectoryAtPath(path: String, completionHandler: ((contents: [FileObject], error: ErrorType?) -> Void)) {
        list(path) { (contents, cursor, error) in
            completionHandler(contents: contents, error: error)
        }
    }
    
    public func attributesOfItemAtPath(path: String, completionHandler: ((attributes: FileObject?, error: ErrorType?) -> Void)) {
        let url = NSURL(string: "https://api.dropboxapi.com/2/files/list_revisions")!
        let request = NSMutableURLRequest(URL: url)
        request.HTTPMethod = "POST"
        request.setValue("Bearer \(credential?.password ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestDictionary = ["path": correctPath(path)!]
        request.HTTPBody = dictionaryToJSON(requestDictionary)?.dataUsingEncoding(NSUTF8StringEncoding)
        let task = session.dataTaskWithRequest(request) { (data, response, error) in
            if let response = response as? NSHTTPURLResponse {
                defer {
                    self.delegateNotify(FileOperation.Create(path: path), error: error)
                }
                let code = FileProviderHTTPErrorCode(rawValue: response.statusCode)
                let dbError: FileProviderDropboxError? = code != nil ? FileProviderDropboxError(code: code!, path: path) : nil
                if let data = data, let jsonStr = String(data: data, encoding: NSUTF8StringEncoding) {
                    let json = self.jsonToDictionary(jsonStr)
                    if (json?["is_deleted"] as? NSNumber)?.boolValue ?? false, let entries = json?["entries"] as? [AnyObject] where entries.count > 0 , let entry = entries[0] as? [String: AnyObject], let file = self.mapToFileObject(entry) {
                        completionHandler(attributes: file, error: dbError)
                        return
                    }
                }
                completionHandler(attributes: nil, error: dbError)
                return
            }
            completionHandler(attributes: nil, error: error)
        }
        task.resume()
    }
    
    public weak var fileOperationDelegate: FileOperationDelegate?
}

extension DropboxFileProvider: FileProviderOperations {
    public func createFolder(folderName: String, atPath: String, completionHandler: SimpleCompletionHandler) {
        let path = (atPath as NSString).stringByAppendingPathComponent(folderName) + "/"
        doOperation(.Create(path: path), completionHandler: completionHandler)
    }
    
    public func createFile(fileAttribs: FileObject, atPath path: String, contents data: NSData?, completionHandler: SimpleCompletionHandler) {
        self.writeContentsAtPath(path, contents: data ?? NSData(), completionHandler: completionHandler)
    }
    
    public func moveItemAtPath(path: String, toPath: String, overwrite: Bool = false, completionHandler: SimpleCompletionHandler) {
        doOperation(.Move(source: path, destination: toPath), completionHandler: completionHandler)
    }
    
    public func copyItemAtPath(path: String, toPath: String, overwrite: Bool = false, completionHandler: SimpleCompletionHandler) {
        doOperation(.Copy(source: path, destination: toPath), completionHandler: completionHandler)
    }
    
    public func removeItemAtPath(path: String, completionHandler: SimpleCompletionHandler) {
        doOperation(.Remove(path: path), completionHandler: completionHandler)
    }
    
    private func doOperation(operation: FileOperation, completionHandler: SimpleCompletionHandler) {
        let url: String
        var path: String?, fromPath: String?, toPath: String?
        switch operation {
        case .Create(path: let p):
            url = "https://api.dropboxapi.com/2/files/create_folder"
            path = p
        case .Copy(source: let fp, destination: let tp):
            url = "https://api.dropboxapi.com/2/files/copy"
            fromPath = fp
            toPath = tp
        case .Move(source: let fp, destination: let tp):
            url = "https://api.dropboxapi.com/2/files/move"
            fromPath = fp
            toPath = tp
        case .Modify(path: let p):
            return
        case .Remove(path: let p):
            url = "https://api.dropboxapi.com/2/files/delete"
            path = p
        case .Link(link: _, target: _):
            return
        }
        let request = NSMutableURLRequest(URL: NSURL(string: url)!)
        request.HTTPMethod = "POST"
        request.setValue("Bearer \(credential?.password ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var requestDictionary = [String: AnyObject]()
        requestDictionary["path"] = correctPath(path)
        requestDictionary["from_path"] = correctPath(fromPath)
        requestDictionary["to_path"] = correctPath(toPath)
        request.HTTPBody = dictionaryToJSON(requestDictionary)?.dataUsingEncoding(NSUTF8StringEncoding)
        let task = session.dataTaskWithRequest(request) { (data, response, error) in
            if let response = response as? NSHTTPURLResponse {
                let code = FileProviderHTTPErrorCode(rawValue: response.statusCode)
                let dbError: FileProviderDropboxError? = code != nil ? FileProviderDropboxError(code: code!, path: path ?? fromPath ?? "") : nil
                defer {
                    self.delegateNotify(operation, error: error ?? dbError)
                }
                /*if let data = data, let jsonStr = String(data: data, encoding: NSUTF8StringEncoding) {
                 let json = self.jsonToDictionary(jsonStr)
                 }*/
                completionHandler?(error: dbError)
                return
            }
            completionHandler?(error: error)
        }
        task.resume()
    }
    
    public func copyLocalFileToPath(localFile: NSURL, toPath: String, completionHandler: SimpleCompletionHandler) {
        NotImplemented()
        let request = NSMutableURLRequest(URL: absoluteURL(toPath))
        request.HTTPMethod = "PUT"
        let task = session.uploadTaskWithRequest(request, fromFile: localFile) { (data, response, error) in
            completionHandler?(error: error)
            self.delegateNotify(.Move(source: localFile.uw_absoluteString, destination: toPath), error: error)
        }
        task.taskDescription = self.dictionaryToJSON(["type": "Copy", "source": localFile.uw_absoluteString, "dest": toPath])
        task.resume()
    }
    
    public func copyPathToLocalFile(path: String, toLocalURL destURL: NSURL, completionHandler: SimpleCompletionHandler) {
        let url = NSURL(string: "https://api.dropboxapi.com/2/files/download")!
        let request = NSMutableURLRequest(URL: url)
        request.HTTPMethod = "GET"
        request.setValue("Bearer \(credential?.password ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestDictionary = ["path": path]
        request.setValue(dictionaryToJSON(requestDictionary), forHTTPHeaderField: "Dropbox-API-Arg")
        let task = session.downloadTaskWithRequest(request, completionHandler: { (cacheURL, response, error) in
            guard let cacheURL = cacheURL, let httpResponse = response as? NSHTTPURLResponse where httpResponse.statusCode < 300 else {
                let code = FileProviderHTTPErrorCode(rawValue: (response as? NSHTTPURLResponse)?.statusCode ?? -1)
                let dbError: FileProviderDropboxError? = code != nil ? FileProviderDropboxError(code: code!, path: path) : nil
                completionHandler?(error: dbError ?? error)
                return
            }
            do {
                try NSFileManager.defaultManager().moveItemAtURL(cacheURL, toURL: destURL)
                completionHandler?(error: nil)
            } catch let e {
                completionHandler?(error: e)
            }
        })
        task.resume()
    }
}

extension DropboxFileProvider: FileProviderReadWrite {
    public func contentsAtPath(path: String, completionHandler: ((contents: NSData?, error: ErrorType?) -> Void)) {
        self.contentsAtPath(path, offset: 0, length: -1, completionHandler: completionHandler)
    }
    
    public func contentsAtPath(path: String, offset: Int64, length: Int, completionHandler: ((contents: NSData?, error: ErrorType?) -> Void)) {
        let url = NSURL(string: "https://api.dropboxapi.com/2/files/download")!
        let request = NSMutableURLRequest(URL: url)
        request.HTTPMethod = "GET"
        request.setValue("Bearer \(credential?.password ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if length > 0 {
            request.setValue("bytes=\(offset)-\(offset + length)", forHTTPHeaderField: "Range")
        } else if offset > 0 && length < 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let requestDictionary = ["path": path]
        request.setValue(dictionaryToJSON(requestDictionary), forHTTPHeaderField: "Dropbox-API-Arg")
        let task = session.downloadTaskWithRequest(request, completionHandler: { (cacheURL, response, error) in
            guard let cacheURL = cacheURL, let httpResponse = response as? NSHTTPURLResponse where httpResponse.statusCode < 300 else {
                let code = FileProviderHTTPErrorCode(rawValue: (response as? NSHTTPURLResponse)?.statusCode ?? -1)
                let dbError: FileProviderDropboxError? = code != nil ? FileProviderDropboxError(code: code!, path: path) : nil
                completionHandler(contents: nil, error: dbError ?? error)
                return
            }
            let destURL = NSURL(fileURLWithPath: NSTemporaryDirectory()).uw_URLByAppendingPathComponent(cacheURL.lastPathComponent ?? "tmpfile")
            do {
                try NSFileManager.defaultManager().moveItemAtURL(cacheURL, toURL: destURL)
                completionHandler(contents: NSData(contentsOfURL: destURL), error: error)
            } catch let e {
                completionHandler(contents: nil, error: e)
            }
        })
        task.resume()
    }
    
    public func writeContentsAtPath(path: String, contents data: NSData, atomically: Bool = false, completionHandler: SimpleCompletionHandler) {
        NotImplemented()
        let url = atomically ? absoluteURL(path).uw_URLByAppendingPathExtension("tmp") : absoluteURL(path)
        let request = NSMutableURLRequest(URL: url)
        request.HTTPMethod = "PUT"
        let task = session.uploadTaskWithRequest(request, fromData: data) { (data, response, error) in
            defer {
                self.delegateNotify(.Modify(path: path), error: error)
            }
            if atomically {
                self.moveItemAtPath((path as NSString).stringByAppendingPathExtension("tmp")!, toPath: path, completionHandler: completionHandler)
            }
            if let error = error {
                // If there is no error, completionHandler has been executed by move command
                completionHandler?(error: error)
            }
        }
        task.taskDescription = self.dictionaryToJSON(["type": "Modify", "source": path])
        task.resume()
    }
    
    public func searchFilesAtPath(path: String, recursive: Bool, query: String, foundItemHandler: ((FileObject) -> Void)?, completionHandler: ((files: [FileObject], error: ErrorType?) -> Void)) {
        NotImplemented()
    }
    
    private func registerNotifcation(path: String, eventHandler: (() -> Void)) {
        /* There is two ways to monitor folders changing in Dropbox. Either using webooks
         * which means you have to implement a server to translate it to push notifications
         * or using apiv2 list_folder/longpoll method. The second one is implemeted here.
         * Tough webhooks are much more efficient, longpoll is much simpler to implement!
         * You can implemnt your own webhook service and replace this method accordingly.
         */
        NotImplemented()
    }
    private func unregisterNotifcation(path: String) {
        NotImplemented()
    }
}

private extension DropboxFileProvider {
    private func list(path: String, cursor: String? = nil, prevContents: [DropboxFileObject] = [], recursive: Bool = false, completionHandler: ((contents: [FileObject], cursor: String?, error: ErrorType?) -> Void)) {
        var requestDictionary = [String: AnyObject]()
        let url: NSURL
        if let cursor = cursor {
            url = NSURL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
            requestDictionary["cursor"] = cursor
        } else {
            url = NSURL(string: "https://api.dropboxapi.com/2/files/list_folder")!
            requestDictionary["path"] = correctPath(path)
            requestDictionary["recursive"] = NSNumber(bool: recursive)
        }
        let request = NSMutableURLRequest(URL: url)
        request.HTTPMethod = "POST"
        request.setValue("Bearer \(credential?.password ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.HTTPBody = dictionaryToJSON(requestDictionary)?.dataUsingEncoding(NSUTF8StringEncoding)
        let task = session.dataTaskWithRequest(request) { (data, response, error) in
            var responseError: FileProviderDropboxError?
            if let code = (response as? NSHTTPURLResponse)?.statusCode where code >= 300, let rCode = FileProviderHTTPErrorCode(rawValue: code) {
                responseError = FileProviderDropboxError(code: rCode, path: path)
            }
            
            if let data = data, let jsonStr = String(data: data, encoding: NSUTF8StringEncoding) {
                let json = self.jsonToDictionary(jsonStr)
                if let entries = json?["entries"] as? [AnyObject] where entries.count > 0 {
                    var files = prevContents
                    for entry in entries {
                        if let entry = entry as? [String: AnyObject], let file = self.mapToFileObject(entry) {
                            files.append(file)
                        }
                    }
                    let ncursor = json?["cursor"] as? String
                    let hasmore = (json?["has_more"] as? NSNumber)?.boolValue ?? false
                    if hasmore {
                        self.list(path, cursor: ncursor, prevContents: files, completionHandler: completionHandler)
                    } else {
                        completionHandler(contents: files, cursor: ncursor, error: responseError ?? error)
                    }
                    return
                }
            }
            completionHandler(contents: [], cursor: nil, error: responseError ?? error)
        }
        task.resume()
    }
}

internal extension DropboxFileProvider {
    private func mapToFileObject(jsonStr: String) -> DropboxFileObject? {
        guard let json = self.jsonToDictionary(jsonStr) else { return nil }
        return self.mapToFileObject(json)
    }
    
    private func mapToFileObject(json: [String: AnyObject]) -> DropboxFileObject? {
        guard let name = json["name"] as? String else { return nil }
        guard let path = json["path_display"] as? String else { return nil }
        let href = NSURL(string: path)!
        let size = (json["size"] as? NSNumber)?.longLongValue ?? -1
        let serverTime = resolveDate(json["server_modified"] as? String ?? "")
        let modifiedDate = resolveDate(json["client_modified"] as? String ?? "")
        let isDirectory = (json[".tag"] as? String) == "folder"
        let isReadonly = (json["sharing_info"]?["read_only"] as? NSNumber)?.boolValue ?? false
        let id = json["id"] as? String
        let rev = json["id"] as? String
        return DropboxFileObject(absoluteURL: href, name: name, path: path, size: size, serverTime: serverTime, createdDate: nil, modifiedDate: modifiedDate, fileType: isDirectory ? .Directory : .Regular, isHidden: false, isReadOnly: isReadonly, id: id, rev: rev)
    }
    
    private func delegateNotify(operation: FileOperation, error: ErrorType?) {
        dispatch_async(dispatch_get_main_queue(), {
            if error == nil {
                self.delegate?.fileproviderSucceed(self, operation: operation)
            } else {
                self.delegate?.fileproviderFailed(self, operation: operation)
            }
        })
    }
}

extension DropboxFileProvider: FileProvider {}

// MARK: URLSession delegate
extension DropboxFileProvider: NSURLSessionDataDelegate, NSURLSessionDownloadDelegate {
    public func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didFinishDownloadingToURL location: NSURL) {
        return
    }
    
    public func URLSession(session: NSURLSession, task: NSURLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let desc = task.taskDescription, let json = jsonToDictionary(desc) else {
            return
        }
        guard let type = json["type"] as? String, let source = json["source"] as? String else {
            return
        }
        let dest = json["dest"] as? String
        let op : FileOperation
        switch type {
        case "Create":
            op = .Create(path: source)
        case "Copy":
            guard let dest = dest else { return }
            op = .Copy(source: source, destination: dest)
        case "Move":
            guard let dest = dest else { return }
            op = .Move(source: source, destination: dest)
        case "Modify":
            op = .Modify(path: source)
        case "Remove":
            op = .Remove(path: source)
        case "Link":
            guard let dest = dest else { return }
            op = .Link(link: source, target: dest)
        default:
            return
        }
        
        let progress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
        
        self.delegate?.fileproviderProgress(self, operation: op, progress: progress)
    }
    
    public func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let desc = downloadTask.taskDescription, let json = jsonToDictionary(desc), let source = json["source"] as? String, dest = json["dest"] as? String else {
            return
        }
        
        self.delegate?.fileproviderProgress(self, operation: .Copy(source: source, destination: dest), progress: Float(totalBytesWritten) / Float(totalBytesExpectedToWrite))
    }
}