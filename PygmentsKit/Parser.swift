//
//  Copyright (c) 2016 Niklas Vangerow
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import os

/// Parse a string and return the tokens and their associated range
public class Parser {
    
    //private static let log = OSLog(subsystem: "uk.notro.PygmentsKit", category: "Parser")
    
    public typealias ParserCallback = (_ range: NSRange, _ token: Token) -> Bool
    
    public enum ParserError: Error {
        case noPygmentizeScript
        case cantGetTempDescriptor
        case pygmentizeStderr(String)
    }
    
    @available(*, unavailable)
    private init() { }
    
    static let bundle = Bundle(for: Parser.self)
    
    static var pygmentsScript: URL? = {
        return bundle.url(forResource: "pygmentize", withExtension: "")
    }()
    
    /// Obtain tokens from pygments for the code and chosen lexer
    ///
    /// - parameter code:  Code string
    /// - parameter lexer: pygments lexer string
    ///
    /// - returns: Array of tokens
    static func tokenize(_ code: String, with lexer: String) throws -> [Token] {
        
        // Save code to temporary directory as stdin is weird
        let codeFileLocation = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pygktmp.\(UUID().uuidString)")
        try code.write(to: codeFileLocation, atomically: false, encoding: .utf8)
        
        defer {
            // delete temp file once we're done with it
            if FileManager.default.fileExists(atPath: codeFileLocation.path) {
                try? FileManager.default.removeItem(at: codeFileLocation)
            }
        }
        
        let arguments = ["-f", "raw", "-l", lexer, codeFileLocation.path]
        let output = try launchPygmentsScript(arguments: arguments)
        
        var tokens = [Token]()
        var lastKind: Token.Kind? = nil
        var lastData = Data()

        for line in output.components(separatedBy: .newlines) {
            let lineSplit = line.components(separatedBy: "\t")
            guard lineSplit.count == 2 else {
                // we are expecting two components, bypass line
                continue
            }
            
            let payloadStr = lineSplit[1]

            // all payload is preceded with u' and ends in '
            // NOTE: the statement above is false due to patch
            guard payloadStr.characters.count >= 2 && payloadStr.characters.count % 2 == 0 else {
                // We don't have enough characters in the payload, missing the unicode string.
                print("Not enough characters in payload \(payloadStr)")
                
                // bail out on malformed input
                break
            }

            let kindStr = lineSplit[0]
            
            var kind: Token.Kind? = Token.Kind(rawValue: kindStr)
            if kind == nil {
                // we shouldn't bypass unknown tokens
                kind = .generic
            }

            if lastKind != nil && lastKind != kind {
                
                if !lastData.isEmpty {
                    guard let payload = String(data: lastData, encoding: .utf8) else {
                        // bail out on malformed input
                        break
                    }
                    
                    tokens.append(Token(kind: lastKind!, payload: payload))
                }

                lastKind = kind
                lastData.removeAll()
            } else if lastKind == nil {
                lastKind = kind
            }
 
            let payloadUni = payloadStr.lowercased().unicodeScalars // NOTE: formaly payloadStr already lowercased
            var itr = payloadUni[payloadUni.index(after: payloadUni.startIndex)..<payloadUni.index(before: payloadUni.endIndex)].makeIterator()

            while true {

                guard let uni1 = itr.next() else { break }
                var ch1 = uni1.value - 0x30
                if ch1 > 9 {
                    ch1 += 0x30 + 10
                    ch1 -= 0x61
                }

                guard let uni2 = itr.next() else { break }
                var ch2 = uni2.value - 0x30
                if ch2 > 9 {
                    ch2 += 0x30 + 10
                    ch2 -= 0x61
                }

                let byte = UInt8((ch1 << 4) + ch2)
                lastData.append(byte)
            }
        }
        
        if lastKind != nil {
            
            if !lastData.isEmpty {
                if let payload = String(data: lastData, encoding: .utf8) {
                    tokens.append(Token(kind: lastKind!, payload: payload))
                }
            }
        }

        return tokens
    }
    
    /// Parse a code string using a pygments lexer and obtain the tokens and their range.
    ///
    /// - parameter code:     Code to parse.
    /// - parameter lexer:    Lexer to tokenise with.
    /// - parameter callback: Called with a range and its token.
    ///
    /// - throws: A ParserError
    public class func parse(_ code: String, with lexer: String, callback: ParserCallback) throws {
        let tokens = try tokenize(code, with: lexer)
        
        let codeNS = code as NSString
        let icount = codeNS.length
        var index = 0
        for token in tokens where index < icount {
            let range = codeNS.range(of: token.payload, options: [], range: NSRange(index..<icount))
            index += (token.payload as NSString).length
            
            guard callback(range, token) else { break }
        }
    }
    
    /// Obtain a suitable lexer for the given filename.
    ///
    /// - parameter filename:     Filename to query.
    ///
    /// - returns: Lexer name, if suitable lexer is found, or nil if not.
    ///
    /// - throws: A ParserError
    public class func findLexer(for filename: String) throws -> String? {
        let arguments = ["-N", (filename as NSString).lastPathComponent]

        let output = (try launchPygmentsScript(arguments: arguments)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        if output.characters.count == 0 {
            return nil
        }
        
        return output
    }
    
    /// Launch built-in pygmentize script and return its error
    ///
    /// - parameter arguments:    Arguments to pass to the script
    ///
    /// - returns: Script output string
    ///
    /// - throws: A ParserError
    static func launchPygmentsScript(arguments: [String]) throws -> String {
        // Get the pygments script path
        guard let pygmentsScript = Parser.pygmentsScript else {
            throw ParserError.noPygmentizeScript
        }
        
        //os_log("Found pygmentize at %{public}s", log: Parser.log, type: .debug, pygmentsScript.path)
        
        // Set up the process
        let pyg = Process()
        pyg.launchPath = "/usr/bin/env"
        var processArguments: [String] = ["python", pygmentsScript.path]
        processArguments.append(contentsOf: arguments)
        pyg.arguments = processArguments
        
        // Get standard output from
        let stdout = Pipe()
        let stderr = Pipe()
        
        // Set up the pipes
        pyg.standardOutput = stdout
        pyg.standardError = stderr
        
        // Launch pygmentize
        pyg.launch()
        
        var stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        var stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        // Wait until we're done
        pyg.waitUntilExit()
        
        guard pyg.terminationStatus == 0 else {
            // We encountered some kind of problem
            throw ParserError.pygmentizeStderr(String(data: stderrData, encoding: .utf8) ?? "")
        }
        
        guard let output = String(data: stdoutData, encoding: .utf8) else {
            return ""
        }

        return output
    }
}

/// Parse a string and return the tokens, their associated range, and attributes for an NSAttributedString
public class AttributedParser {
    public typealias AttributedParserCallback = (_ range: NSRange, _ token: Token, _ attributes: [String: Any]) -> Bool
    
    @available(*, unavailable)
    private init() { }
    
    /// Parse a code string using a pygments lexer and colour it with the provided theme,
    /// returning attributes that can be used with an NSAttributedString.
    ///
    /// - parameter code:     Code to parse.
    /// - parameter lexer:    Lexer to tokenise with.
    /// - parameter theme:    Theme to use for generating NSAttributedString attributes.
    /// - parameter callback: Called with a range, its token, and attributes.
    ///
    /// - throws: A ParserError
    public class func parse(_ code: String, with lexer: String, theme: Theme, callback: AttributedParserCallback) throws {
        try Parser.parse(code, with: lexer) { (range, token) in
            guard let scopeSelector = token.kind.scope,
                let scope = theme.resolveScope(selector: scopeSelector) else {
                    return true // just bypass scope
            }
            
            // Populate attributes
            var attributes = [String: Any]()
            if let foreground = scope.foreground {
                attributes[NSForegroundColorAttributeName] = foreground
            }
            
            if let background = scope.background {
                attributes[NSBackgroundColorAttributeName] = background
            }
            
            // Ignore font styles for now.
            // TODO: Don't ignore font styles 
//            if let fontStyles = scope.fontStyles {
//            }
            
            // do not propagate not affected ranges
            guard !attributes.isEmpty else { return true }
            
            // emit range and attributes
            return callback(range, token, attributes)
        }
    }
}
