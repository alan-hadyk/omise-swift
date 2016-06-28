import Foundation

public class Request<TOperation: Operation>: NSObject {
    public typealias Callback = Failable<TOperation.Result> -> ()
    
    private var dataTask: NSURLSessionTask? = nil
    private var callback: Callback? = nil
    
    public let client: Client
    public let operation: TOperation
    public let urlRequest: NSURLRequest
    
    public init(client: Client, operation: TOperation, callback: Callback?) throws {
        self.callback = callback
        
        self.client = client
        self.operation = operation
        self.urlRequest = try Request.buildURLRequest(client.config, operation: operation)
        super.init()
        
        self.dataTask = client.session.dataTaskWithRequest(urlRequest, completionHandler: didComplete)
    }
    
    static func buildURLRequest(config: Config, operation: TOperation) throws -> NSURLRequest {
        guard let host = operation.url.host else {
            throw OmiseError.Unexpected(message: "requested operation has invalid url.")
        }
        
        let apiKey = try selectApiKey(config, host: host)
        let auth = try encodeApiKeyForAuthorization(apiKey)
        
        let request = NSMutableURLRequest(URL: operation.url)
        request.HTTPMethod = operation.method
        request.cachePolicy = .UseProtocolCachePolicy
        request.timeoutInterval = 6.0
        request.HTTPBody = operation.payload
        request.addValue(auth, forHTTPHeaderField: "Authorization")
        return request
    }
    
    static func selectApiKey(config: Config, host: String) throws -> String {
        let key: String?
        if host.containsString("vault.omise.co") {
            key = config.publicKey
        } else {
            key = config.secretKey
        }
        
        guard let resolvedKey = key else {
            throw OmiseError.Configuration(message: "no api key for host \(host).")
        }
        
        return resolvedKey
    }
    
    static func encodeApiKeyForAuthorization(apiKey: String) throws -> String {
        let data = "\(apiKey):X".dataUsingEncoding(NSUTF8StringEncoding)
        guard let md5 = data?.base64EncodedStringWithOptions(.Encoding64CharacterLineLength) else {
            throw OmiseError.Configuration(message: "bad API key (encoding failed.)")
        }
        
        return "Basic \(md5)"
    }
    
    
    func start() -> Request<TOperation> {
        dataTask?.resume()
        return self
    }
    
    private func didComplete(data: NSData?, response: NSURLResponse?, error: NSError?) {
        // no one's in the forest to hear the leaf falls.
        guard callback != nil else { return }
        
        if let err = error {
            return performCallback(.Fail(err: .IO(err: err)))
        }
        
        guard let httpResponse = response as? NSHTTPURLResponse else {
            return performCallback(.Fail(err: .Unexpected(message: "no error and no response.")))
        }
        
        guard let data = data else {
            return performCallback(.Fail(err: .Unexpected(message: "empty response.")))
        }
        
        do {
            switch httpResponse.statusCode {
            case 400..<600:
                let err: APIError = try OmiseSerializer.deserialize(data)
                return performCallback(.Fail(err: .API(err: err)))
                
            case 200..<300:
                let result: TOperation.Result = try OmiseSerializer.deserialize(data)
                return performCallback(.Success(result: result))
                
            default:
                return performCallback(.Fail(err: .Unexpected(message: "unrecognized HTTP status code: \(httpResponse.statusCode)")))
            }
            
        } catch let err as NSError {
            return performCallback(.Fail(err: .IO(err: err)))
        } catch let err as OmiseError {
            return performCallback(.Fail(err: err))
        }
    }
    
    private func performCallback(result: Failable<TOperation.Result>) {
        guard let cb = callback else { return }
        client.performCallback { cb(result) }
    }
}