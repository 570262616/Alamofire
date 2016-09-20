//
//  MultipartFormData.swift
//
//  Copyright (c) 2014-2016 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

#if os(iOS) || os(watchOS) || os(tvOS)
import MobileCoreServices
#elseif os(OSX)
import CoreServices
#endif

/**
    Constructs `multipart/form-data` for uploads within an HTTP or HTTPS body. There are currently two ways to encode
    multipart form data. The first way is to encode the data directly in memory. This is very efficient, but can lead
    to memory issues if the dataset is too large. The second way is designed for larger datasets and will write all the
    data to a single file on disk with all the proper boundary segmentation. The second approach MUST be used for
    larger datasets such as video content, otherwise your app may run out of memory when trying to encode the dataset.

    For more information on `multipart/form-data` in general, please refer to the RFC-2388 and RFC-2045 specs as well
    and the w3 form documentation.

    - https://www.ietf.org/rfc/rfc2388.txt
    - https://www.ietf.org/rfc/rfc2045.txt
    - https://www.w3.org/TR/html401/interact/forms.html#h-17.13
*/
public class MultipartFormData {

    // MARK: - Helper Types

    struct EncodingCharacters {
        static let CRLF = "\r\n"
    }

    struct BoundaryGenerator {
        enum BoundaryType {
            case initial, encapsulated, final
        }

        static func randomBoundary() -> String {
            return String(format: "alamofire.boundary.%08x%08x", arc4random(), arc4random())
        }

        static func boundaryData(boundaryType: BoundaryType, boundary: String) -> Data {
            let boundaryText: String

            switch boundaryType {
            case .initial:
                boundaryText = "--\(boundary)\(EncodingCharacters.CRLF)"
            case .encapsulated:
                boundaryText = "\(EncodingCharacters.CRLF)--\(boundary)\(EncodingCharacters.CRLF)"
            case .final:
                boundaryText = "\(EncodingCharacters.CRLF)--\(boundary)--\(EncodingCharacters.CRLF)"
            }

            return boundaryText.data(using: String.Encoding.utf8, allowLossyConversion: false)!
        }
    }

    class BodyPart {
        let headers: [String: String]
        let bodyStream: InputStream
        let bodyContentLength: UInt64
        var hasInitialBoundary = false
        var hasFinalBoundary = false

        init(headers: [String: String], bodyStream: InputStream, bodyContentLength: UInt64) {
            self.headers = headers
            self.bodyStream = bodyStream
            self.bodyContentLength = bodyContentLength
        }
    }

    // MARK: - Properties

    /// The `Content-Type` header value containing the boundary used to generate the `multipart/form-data`.
    public var contentType: String { return "multipart/form-data; boundary=\(boundary)" }

    /// The content length of all body parts used to generate the `multipart/form-data` not including the boundaries.
    public var contentLength: UInt64 { return bodyParts.reduce(0) { $0 + $1.bodyContentLength } }

    /// The boundary used to separate the body parts in the encoded form data.
    public let boundary: String

    private var bodyParts: [BodyPart]
    private var bodyPartError: NSError?
    private let streamBufferSize: Int

    // MARK: - Lifecycle

    /**
        Creates a multipart form data object.

        - returns: The multipart form data object.
    */
    public init() {
        self.boundary = BoundaryGenerator.randomBoundary()
        self.bodyParts = []

        /**
         *  The optimal read/write buffer size in bytes for input and output streams is 1024 (1KB). For more
         *  information, please refer to the following article:
         *    - https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/Streams/Articles/ReadingInputStreams.html
         */

        self.streamBufferSize = 1024
    }

    // MARK: - Body Parts

    /**
        Creates a body part from the data and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}` (HTTP Header)
        - Encoded data
        - Multipart form boundary

        - parameter data: The data to encode into the multipart form data.
        - parameter name: The name to associate with the data in the `Content-Disposition` HTTP header.
    */
    public func appendBodyPart(data: Data, name: String) {
        let headers = contentHeaders(name: name)
        let stream = InputStream(data: data)
        let length = UInt64(data.count)

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the data and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}` (HTTP Header)
        - `Content-Type: #{generated mimeType}` (HTTP Header)
        - Encoded data
        - Multipart form boundary

        - parameter data:     The data to encode into the multipart form data.
        - parameter name:     The name to associate with the data in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the data content type in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(data: Data, name: String, mimeType: String) {
        let headers = contentHeaders(name: name, mimeType: mimeType)
        let stream = InputStream(data: data)
        let length = UInt64(data.count)

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the data and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}; filename=#{filename}` (HTTP Header)
        - `Content-Type: #{mimeType}` (HTTP Header)
        - Encoded file data
        - Multipart form boundary

        - parameter data:     The data to encode into the multipart form data.
        - parameter name:     The name to associate with the data in the `Content-Disposition` HTTP header.
        - parameter fileName: The filename to associate with the data in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the data in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(data: Data, name: String, fileName: String, mimeType: String) {
        let headers = contentHeaders(name: name, fileName: fileName, mimeType: mimeType)
        let stream = InputStream(data: data)
        let length = UInt64(data.count)

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the file and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}; filename=#{generated filename}` (HTTP Header)
        - `Content-Type: #{generated mimeType}` (HTTP Header)
        - Encoded file data
        - Multipart form boundary

        The filename in the `Content-Disposition` HTTP header is generated from the last path component of the
        `fileURL`. The `Content-Type` HTTP header MIME type is generated by mapping the `fileURL` extension to the
        system associated MIME type.

        - parameter fileURL: The URL of the file whose content will be encoded into the multipart form data.
        - parameter name:    The name to associate with the file content in the `Content-Disposition` HTTP header.
    */
    public func appendBodyPart(fileURL: URL, name: String) {
        let fileName = fileURL.lastPathComponent
        let pathExtension = fileURL.pathExtension

        if !fileName.isEmpty && !pathExtension.isEmpty {
            let mimeType = mimeTypeForPathExtension(pathExtension)
            appendBodyPart(fileURL: fileURL, name: name, fileName: fileName, mimeType: mimeType)
        } else {
            let failureReason = "Failed to extract the fileName of the provided URL: \(fileURL)"
            setBodyPartError(code: NSURLErrorBadURL, failureReason: failureReason)
        }
    }

    /**
        Creates a body part from the file and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - Content-Disposition: form-data; name=#{name}; filename=#{filename} (HTTP Header)
        - Content-Type: #{mimeType} (HTTP Header)
        - Encoded file data
        - Multipart form boundary

        - parameter fileURL:  The URL of the file whose content will be encoded into the multipart form data.
        - parameter name:     The name to associate with the file content in the `Content-Disposition` HTTP header.
        - parameter fileName: The filename to associate with the file content in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the file content in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(fileURL: URL, name: String, fileName: String, mimeType: String) {
        let headers = contentHeaders(name: name, fileName: fileName, mimeType: mimeType)

        //============================================================
        //                 Check 1 - is file URL?
        //============================================================

        guard fileURL.isFileURL else {
            let failureReason = "The file URL does not point to a file URL: \(fileURL)"
            setBodyPartError(code: NSURLErrorBadURL, failureReason: failureReason)
            return
        }

        //============================================================
        //              Check 2 - is file URL reachable?
        //============================================================

        let isReachable = (fileURL as NSURL).checkPromisedItemIsReachableAndReturnError(nil)

        guard isReachable else {
            setBodyPartError(code: NSURLErrorBadURL, failureReason: "The file URL is not reachable: \(fileURL)")
            return
        }

        //============================================================
        //            Check 3 - is file URL a directory?
        //============================================================

        var isDirectory: ObjCBool = false
        let path = fileURL.path

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue else
        {
            let failureReason = "The file URL is a directory, not a file: \(fileURL)"
            setBodyPartError(code: NSURLErrorBadURL, failureReason: failureReason)
            return
        }

        //============================================================
        //          Check 4 - can the file size be extracted?
        //============================================================

        var bodyContentLength: UInt64?

        do {
            if let fileSize = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
            {
                bodyContentLength = fileSize.uint64Value
            }
        }
        catch {
            // No Op
        }

        guard let length = bodyContentLength else {
            let failureReason = "Could not fetch attributes from the file URL: \(fileURL)"
            setBodyPartError(code: NSURLErrorBadURL, failureReason: failureReason)
            return
        }

        //============================================================
        //       Check 5 - can a stream be created from file URL?
        //============================================================

        guard let stream = InputStream(url: fileURL) else {
            let failureReason = "Failed to create an input stream from the file URL: \(fileURL)"
            setBodyPartError(code: NSURLErrorCannotOpenFile, failureReason: failureReason)
            return
        }

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the stream and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}; filename=#{filename}` (HTTP Header)
        - `Content-Type: #{mimeType}` (HTTP Header)
        - Encoded stream data
        - Multipart form boundary

        - parameter stream:   The input stream to encode in the multipart form data.
        - parameter length:   The content length of the stream.
        - parameter name:     The name to associate with the stream content in the `Content-Disposition` HTTP header.
        - parameter fileName: The filename to associate with the stream content in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the stream content in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(
        stream: InputStream,
        length: UInt64,
        name: String,
        fileName: String,
        mimeType: String)
    {
        let headers = contentHeaders(name: name, fileName: fileName, mimeType: mimeType)
        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part with the headers, stream and length and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - HTTP headers
        - Encoded stream data
        - Multipart form boundary

        - parameter stream:  The input stream to encode in the multipart form data.
        - parameter length:  The content length of the stream.
        - parameter headers: The HTTP headers for the body part.
    */
    public func appendBodyPart(stream: InputStream, length: UInt64, headers: [String: String]) {
        let bodyPart = BodyPart(headers: headers, bodyStream: stream, bodyContentLength: length)
        bodyParts.append(bodyPart)
    }

    // MARK: - Data Encoding

    /**
        Encodes all the appended body parts into a single `NSData` object.

        It is important to note that this method will load all the appended body parts into memory all at the same
        time. This method should only be used when the encoded data will have a small memory footprint. For large data
        cases, please use the `writeEncodedDataToDisk(fileURL:completionHandler:)` method.

        - throws: An `NSError` if encoding encounters an error.

        - returns: The encoded `Data` if encoding is successful.
    */
    public func encode() throws -> Data {
        if let bodyPartError = bodyPartError {
            throw bodyPartError
        }

        var encoded = Data()

        bodyParts.first?.hasInitialBoundary = true
        bodyParts.last?.hasFinalBoundary = true

        for bodyPart in bodyParts {
            let encodedData = try encodeBodyPart(bodyPart)
            encoded.append(encodedData)
        }

        return encoded
    }

    /**
        Writes the appended body parts into the given file URL.

        This process is facilitated by reading and writing with input and output streams, respectively. Thus,
        this approach is very memory efficient and should be used for large body part data.

        - parameter fileURL: The file URL to write the multipart form data into.

        - throws: An `NSError` if encoding encounters an error.
    */
    public func writeEncodedDataToDisk(_ fileURL: URL) throws {
        if let bodyPartError = bodyPartError {
            throw bodyPartError
        }


        if FileManager.default.fileExists(atPath: fileURL.path) {
            let failureReason = "A file already exists at the given file URL: \(fileURL)"
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, failureReason: failureReason)
        } else if !fileURL.isFileURL {
            let failureReason = "The URL does not point to a valid file: \(fileURL)"
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, failureReason: failureReason)
        }

        let outputStream: OutputStream

        if let possibleOutputStream = OutputStream(url: fileURL, append: false) {
            outputStream = possibleOutputStream
        } else {
            let failureReason = "Failed to create an output stream with the given URL: \(fileURL)"
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile, failureReason: failureReason)
        }

        outputStream.open()

        self.bodyParts.first?.hasInitialBoundary = true
        self.bodyParts.last?.hasFinalBoundary = true

        for bodyPart in self.bodyParts {
            try writeBodyPart(bodyPart, toOutputStream: outputStream)
        }

        outputStream.close()
    }

    // MARK: - Private - Body Part Encoding

    private func encodeBodyPart(_ bodyPart: BodyPart) throws -> Data {
        var encoded = Data()

        let initialData = bodyPart.hasInitialBoundary ? initialBoundaryData() : encapsulatedBoundaryData()
        encoded.append(initialData)

        let headerData = encodeHeaderDataForBodyPart(bodyPart)
        encoded.append(headerData)

        let bodyStreamData = try encodeBodyStreamDataForBodyPart(bodyPart)
        encoded.append(bodyStreamData)

        if bodyPart.hasFinalBoundary {
            encoded.append(finalBoundaryData())
        }

        return encoded as Data
    }

    private func encodeHeaderDataForBodyPart(_ bodyPart: BodyPart) -> Data {
        var headerText = ""

        for (key, value) in bodyPart.headers {
            headerText += "\(key): \(value)\(EncodingCharacters.CRLF)"
        }
        headerText += EncodingCharacters.CRLF

        return headerText.data(using: String.Encoding.utf8, allowLossyConversion: false)!
    }

    private func encodeBodyStreamDataForBodyPart(_ bodyPart: BodyPart) throws -> Data {
        let inputStream = bodyPart.bodyStream
        inputStream.open()

        var error: Error?
        var encoded = Data()

        while inputStream.hasBytesAvailable {
            var buffer = [UInt8](repeating: 0, count: streamBufferSize)
            let bytesRead = inputStream.read(&buffer, maxLength: streamBufferSize)

            if inputStream.streamError != nil {
                error = inputStream.streamError
                break
            }

            if bytesRead > 0 {
                encoded.append(buffer, count: bytesRead)
            } else if bytesRead < 0 {
                let failureReason = "Failed to read from input stream: \(inputStream)"
                error = NSError(domain: NSURLErrorDomain, code: .inputStreamReadFailed, failureReason: failureReason)
                break
            } else {
                break
            }
        }

        inputStream.close()

        if let error = error {
            throw error
        }

        return encoded as Data
    }

    // MARK: - Private - Writing Body Part to Output Stream

    private func writeBodyPart(_ bodyPart: BodyPart, toOutputStream outputStream: OutputStream) throws {
        try writeInitialBoundaryDataForBodyPart(bodyPart, toOutputStream: outputStream)
        try writeHeaderDataForBodyPart(bodyPart, toOutputStream: outputStream)
        try writeBodyStreamForBodyPart(bodyPart, toOutputStream: outputStream)
        try writeFinalBoundaryDataForBodyPart(bodyPart, toOutputStream: outputStream)
    }

    private func writeInitialBoundaryDataForBodyPart(
        _ bodyPart: BodyPart,
        toOutputStream outputStream: OutputStream)
        throws
    {
        let initialData = bodyPart.hasInitialBoundary ? initialBoundaryData() : encapsulatedBoundaryData()
        return try writeData(initialData, toOutputStream: outputStream)
    }

    private func writeHeaderDataForBodyPart(_ bodyPart: BodyPart, toOutputStream outputStream: OutputStream) throws {
        let headerData = encodeHeaderDataForBodyPart(bodyPart)
        return try writeData(headerData, toOutputStream: outputStream)
    }

    private func writeBodyStreamForBodyPart(_ bodyPart: BodyPart, toOutputStream outputStream: OutputStream) throws {
        let inputStream = bodyPart.bodyStream
        inputStream.open()

        while inputStream.hasBytesAvailable {
            var buffer = [UInt8](repeating: 0, count: streamBufferSize)
            let bytesRead = inputStream.read(&buffer, maxLength: streamBufferSize)

            if let streamError = inputStream.streamError {
                throw streamError
            }

            if bytesRead > 0 {
                if buffer.count != bytesRead {
                    buffer = Array(buffer[0..<bytesRead])
                }

                try writeBuffer(&buffer, toOutputStream: outputStream)
            } else if bytesRead < 0 {
                let failureReason = "Failed to read from input stream: \(inputStream)"
                throw NSError(domain: NSURLErrorDomain, code: .inputStreamReadFailed, failureReason: failureReason)
            } else {
                break
            }
        }

        inputStream.close()
    }

    private func writeFinalBoundaryDataForBodyPart(
        _ bodyPart: BodyPart,
        toOutputStream outputStream: OutputStream)
        throws
    {
        if bodyPart.hasFinalBoundary {
            return try writeData(finalBoundaryData(), toOutputStream: outputStream)
        }
    }

    // MARK: - Private - Writing Buffered Data to Output Stream

    private func writeData(_ data: Data, toOutputStream outputStream: OutputStream) throws {
        var buffer = [UInt8](repeating: 0, count: data.count)
        (data as NSData).getBytes(&buffer, length: data.count)

        return try writeBuffer(&buffer, toOutputStream: outputStream)
    }

    private func writeBuffer(_ buffer: inout [UInt8], toOutputStream outputStream: OutputStream) throws {
        var bytesToWrite = buffer.count

        while bytesToWrite > 0 {
            if outputStream.hasSpaceAvailable {
                let bytesWritten = outputStream.write(buffer, maxLength: bytesToWrite)

                if let streamError = outputStream.streamError {
                    throw streamError
                }

                if bytesWritten < 0 {
                    let failureReason = "Failed to write to output stream: \(outputStream)"
                    throw NSError(domain: NSURLErrorDomain, code: .outputStreamWriteFailed, failureReason: failureReason)
                }

                bytesToWrite -= bytesWritten

                if bytesToWrite > 0 {
                    buffer = Array(buffer[bytesWritten..<buffer.count])
                }
            } else if let streamError = outputStream.streamError {
                throw streamError
            }
        }
    }

    // MARK: - Private - Mime Type

    private func mimeTypeForPathExtension(_ pathExtension: String) -> String {
        if let id = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, pathExtension as CFString, nil)?.takeRetainedValue(),
           let contentType = UTTypeCopyPreferredTagWithClass(id, kUTTagClassMIMEType)?.takeRetainedValue()
        {
            return contentType as String
        }

        return "application/octet-stream"
    }

    // MARK: - Private - Content Headers

    private func contentHeaders(name: String) -> [String: String] {
        return ["Content-Disposition": "form-data; name=\"\(name)\""]
    }

    private func contentHeaders(name: String, mimeType: String) -> [String: String] {
        return [
            "Content-Disposition": "form-data; name=\"\(name)\"",
            "Content-Type": "\(mimeType)"
        ]
    }

    private func contentHeaders(name: String, fileName: String, mimeType: String) -> [String: String] {
        return [
            "Content-Disposition": "form-data; name=\"\(name)\"; filename=\"\(fileName)\"",
            "Content-Type": "\(mimeType)"
        ]
    }

    // MARK: - Private - Boundary Encoding

    private func initialBoundaryData() -> Data {
        return BoundaryGenerator.boundaryData(boundaryType: .initial, boundary: boundary)
    }

    private func encapsulatedBoundaryData() -> Data {
        return BoundaryGenerator.boundaryData(boundaryType: .encapsulated, boundary: boundary)
    }

    private func finalBoundaryData() -> Data {
        return BoundaryGenerator.boundaryData(boundaryType: .final, boundary: boundary)
    }

    // MARK: - Private - Errors

    private func setBodyPartError(code: Int, failureReason: String) {
        guard bodyPartError == nil else { return }
        bodyPartError = NSError(domain: NSURLErrorDomain, code: code, failureReason: failureReason)
    }
}
