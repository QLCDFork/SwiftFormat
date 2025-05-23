//
//  Formatter.swift
//  SwiftFormat
//
//  Created by Nick Lockwood on 12/08/2016.
//  Copyright 2016 Nick Lockwood
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/SwiftFormat
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

/// This is a utility class used for manipulating a tokenized source file.
/// It doesn't actually contain any logic for formatting, but provides
/// utility methods for enumerating and adding/removing/replacing tokens.
/// The primary advantage it provides over operating on the token array
/// directly is that it allows mutation during enumeration, and
/// transparently handles changes that affect the current token index.
public class Formatter: NSObject {
    private var enumerationIndex = -1
    private var disabledCount = 0
    private var disabledNext = 0
    private var ruleDisabled = false
    private var tempOptions: FormatOptions?
    private var wasNextDirective = false
    private var autoUpdatingReferences = [WeakAutoUpdatingReference]()

    /// Formatting range
    public var range: Range<Int>?

    /// Current rule, used for handling comment directives
    var currentRule: FormatRule? {
        didSet {
            disabledCount = 0
            disabledNext = 0
            ruleDisabled = false
            wasNextDirective = false
            if let options = tempOptions {
                self.options = options
                tempOptions = nil
            }
        }
    }

    /// Is current rule enabled
    var isEnabled: Bool {
        if ruleDisabled || disabledCount + disabledNext > 0 ||
            range?.contains(enumerationIndex) == false
        {
            return false
        }
        return true
    }

    /// Directives that can be used in comments, e.g. `// swiftformat:disable rule`
    let directives = ["disable", "enable", "options", "sort"]

    /// Process a comment token (which may contain directives)
    func processCommentBody(_ comment: String, at index: Int) {
        var prefix = "swiftformat:"
        guard let range = comment.range(of: prefix) else {
            return
        }
        let comment = String(comment[range.upperBound...])
        guard let directive = directives.first(where: {
            comment.hasPrefix($0)
        }) else {
            let parts = comment.components(separatedBy: ":")
            var directive = parts[0]
            if let range = directive.rangeOfCharacter(from: .whitespacesAndNewlines) {
                directive = String(directive[..<range.lowerBound])
            }
            if directive.isEmpty {
                return fatalError("Expected directive after 'swiftformat:' prefix", at: index)
            }
            return fatalError("Unknown directive swiftformat:\(directive)", at: index)
        }
        prefix = directive
        wasNextDirective = comment.hasPrefix("\(prefix):next")
        let offset = (wasNextDirective ? "\(prefix):next" : prefix).endIndex
        let argumentsString = String(comment[offset...])
        func containsRule() -> Bool {
            guard let rule = currentRule else {
                return false
            }
            // TODO: handle typos, error for invalid rule names
            // TODO: warn when trying to enable a rule that isn't enabled at file level
            return argumentsString.range(of: "\\b(\(rule.name)|all)\\b", options: [
                .regularExpression, .caseInsensitive,
            ]) != nil
        }
        switch directive {
        case "options":
            if wasNextDirective {
                tempOptions = options
            }
            let args = parseArguments(argumentsString)
            do {
                let args = try preprocessArguments(args, formattingArguments + internalArguments)
                if let arg = args["1"] {
                    throw FormatError.options("Unknown option \(arg)")
                }
                var options = Options(formatOptions: self.options)
                try options.addArguments(args, in: "")
                self.options = options.formatOptions ?? self.options
            } catch {
                return fatalError("\(error)", at: index)
            }
        case "disable" where containsRule():
            if wasNextDirective {
                disabledNext = 1
            } else {
                disabledCount += 1
            }
        case "enable" where containsRule():
            if wasNextDirective {
                disabledNext = -1
            } else {
                disabledCount -= 1
            }
        default:
            return
        }
    }

    /// Process a linebreak (used to cancel disable/enable:next directive)
    func processLinebreak() {
        if wasNextDirective {
            wasNextDirective = false
        } else {
            disabledNext = 0
            if let options = tempOptions {
                self.options = options
                tempOptions = nil
            }
        }
    }

    /// The options that the formatter was initialized with
    public private(set) var options: FormatOptions

    /// The token array managed by the formatter (read-only)
    public private(set) var tokens: [Token]

    /// Create a new formatter instance from a token array
    public init(_ tokens: [Token], options: FormatOptions = FormatOptions(),
                trackChanges: Bool = false, range: Range<Int>? = nil)
    {
        self.tokens = tokens
        self.options = options
        self.trackChanges = trackChanges
        self.range = range
    }

    // MARK: changes made

    /// Change record
    public struct Change: Equatable {
        public let line: Int
        public let rule: FormatRule
        public let filePath: String?
        public let isMove: Bool

        public var help: String {
            stripMarkdown(rule.help).replacingOccurrences(of: "\n", with: " ")
        }

        public func description(asError: Bool) -> String {
            "\(filePath ?? ""):\(line):1: \(asError ? "error" : "warning"): (\(rule.name)) \(help)"
        }
    }

    /// Changes made
    public private(set) var changes = [Change]()

    /// Should formatter track changes?
    private let trackChanges: Bool

    private func trackChange(at index: Int, isMove: Bool = false) {
        guard trackChanges else { return }
        changes.append(Change(
            line: originalLine(at: index),
            rule: currentRule ?? .none,
            filePath: options.fileInfo.filePath,
            isMove: isMove
        ))
    }

    private func updateRange(at index: Int, delta: Int) {
        autoUpdatingReferences.updateRanges(at: index, delta: delta)

        guard let range = range, range.contains(index) else {
            return
        }
        self.range = range.lowerBound ..< range.upperBound + delta
    }

    // MARK: errors and warning

    private(set) var errors = [FormatError]()

    func fatalError(_ error: String, at tokenIndex: Int) {
        let line = originalLine(at: tokenIndex)
        var message = error + " on line \(line)"

        if let currentRuleName = currentRule?.name {
            message = "[\(currentRuleName)] \(message)"
        }

        errors.append(.parsing(message))
        ruleDisabled = true
    }
}

public extension Formatter {
    // MARK: access and mutation

    /// Returns the token at the specified index, or nil if index is invalid
    func token(at index: Int) -> Token? {
        tokens.indices.contains(index) ? tokens[index] : nil
    }

    /// Replaces the token at the specified index with one or more new tokens
    func replaceToken(at index: Int, with tokens: ArraySlice<Token>) {
        if tokens.isEmpty {
            removeToken(at: index)
        } else if let token = tokens.first {
            replaceToken(at: index, with: token)
            insert(tokens.dropFirst(), at: index + 1)
        }
    }

    /// Replaces the token at the specified index with one or more new tokens
    func replaceToken(at index: Int, with tokens: [Token]) {
        replaceToken(at: index, with: ArraySlice(tokens))
    }

    /// Replaces the token at the specified index with a new token
    func replaceToken(at index: Int, with token: Token) {
        replaceToken(at: index, with: token, isMove: false)
    }

    /// Replaces the token at the specified index with a new token
    private func replaceToken(at index: Int, with token: Token, isMove: Bool) {
        if trackChanges, token.string != tokens[index].string {
            trackChange(at: index, isMove: isMove)
        }
        tokens[index] = token
    }

    /// Replaces the tokens in the specified range with new tokens
    @discardableResult
    func replaceTokens(in range: Range<Int>, with tokens: ArraySlice<Token>) -> Int {
        replaceTokens(in: range, with: tokens, isMove: false)
    }

    /// Replaces the tokens in the specified range with new tokens
    @discardableResult
    private func replaceTokens(in range: Range<Int>, with tokens: ArraySlice<Token>, isMove: Bool) -> Int {
        let max = min(range.count, tokens.count)
        for i in 0 ..< max {
            replaceToken(at: range.lowerBound + i, with: tokens[tokens.startIndex + i], isMove: isMove)
        }
        if range.count > max {
            for index in range.dropFirst(max).reversed() {
                removeToken(at: index, isMove: isMove)
            }
        } else if tokens.count > max {
            insert(tokens.dropFirst(max), at: range.lowerBound + max, isMove: isMove)
        }
        return tokens.count - range.count
    }

    /// Replaces the tokens in the specified range with new tokens
    @discardableResult
    func replaceTokens(in range: Range<Int>, with tokens: [Token]) -> Int {
        replaceTokens(in: range, with: ArraySlice(tokens))
    }

    /// Replaces the tokens in the specified range with a new token
    @discardableResult
    func replaceTokens(in range: Range<Int>, with token: Token) -> Int {
        switch range.count {
        case 1:
            replaceToken(at: range.lowerBound, with: token)
        case 0:
            insert(token, at: range.lowerBound)
        default:
            replaceToken(at: range.lowerBound, with: token)
            removeTokens(in: range.dropFirst())
        }
        return 1 - range.count
    }

    /// Replaces the tokens in the specified range with new tokens
    @discardableResult
    func replaceTokens(in range: ClosedRange<Int>, with tokens: ArraySlice<Token>) -> Int {
        replaceTokens(in: range.lowerBound ..< range.upperBound + 1, with: tokens)
    }

    /// Replaces the tokens in the specified closed range with new tokens
    @discardableResult
    func replaceTokens(in range: ClosedRange<Int>, with tokens: [Token]) -> Int {
        replaceTokens(in: range.lowerBound ..< range.upperBound + 1, with: tokens)
    }

    /// Replaces the tokens in the specified closed range with a new token
    @discardableResult
    func replaceTokens(in range: ClosedRange<Int>, with token: Token) -> Int {
        replaceTokens(in: range.lowerBound ..< range.upperBound + 1, with: token)
    }

    /// Replaces all of the tokens in the given range with the given new tokens,
    /// diffing the lines and tracking lines that move without changes.
    func diffAndReplaceTokens(in rangeToUpdate: ClosedRange<Int>, with updatedTokens: [Token]) {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else {
            // Swift's diffing implementation is only available in macOS 10.15+
            replaceTokens(in: rangeToUpdate, with: updatedTokens)
            return
        }

        // The diffing implementation below is zero-indexed related to the formatter,
        // so the range we diff also needs to be zero-indexed.
        let diffRange = 0 ... rangeToUpdate.upperBound
        let originalTokens = Array(tokens[diffRange])
        let updatedTokens = Array(tokens[0 ..< rangeToUpdate.lowerBound]) + updatedTokens

        let originalLines = originalTokens.lines
        let updatedLines = updatedTokens.lines
        let difference = updatedLines.difference(from: originalLines).inferringMoves()

        for step in difference {
            switch step {
            case let .insert(lineIndex, line, movedFromLineIndex):
                let lineRanges = tokens.lineRanges
                if lineIndex >= lineRanges.count {
                    insert(line, at: tokens.endIndex, isMove: movedFromLineIndex != nil)
                } else {
                    insert(line, at: lineRanges[lineIndex].lowerBound, isMove: movedFromLineIndex != nil)
                }

            case let .remove(lineIndex, _, movedToLineIndex):
                for index in tokens.lineRanges[lineIndex].reversed() {
                    removeToken(at: index, isMove: movedToLineIndex != nil)
                }
            }
        }
    }

    /// Removes the token at the specified index
    func removeToken(at index: Int) {
        removeToken(at: index, isMove: false)
    }

    private func removeToken(at index: Int, isMove: Bool) {
        trackChange(at: index, isMove: isMove)
        updateRange(at: index, delta: -1)
        tokens.remove(at: index)
        if enumerationIndex >= index {
            enumerationIndex -= 1
        }
    }

    /// Removes the tokens in the specified range
    func removeTokens(in range: Range<Int>) {
        for index in range.reversed() {
            removeToken(at: index)
        }
    }

    /// Removes the tokens in the specified closed range
    func removeTokens(in range: ClosedRange<Int>) {
        removeTokens(in: range.lowerBound ..< range.upperBound + 1)
    }

    /// Removes the tokens in the specified set of ranges, that must not overlay
    func removeTokens(in rangesToRemove: [ClosedRange<Int>]) {
        // We remove the ranges in reverse order, so that removing
        // one range doesn't invalidate the existings of the other ranges
        let rangeRemovalOrder = rangesToRemove
            .sorted(by: { $0.startIndex < $1.startIndex })
            .reversed()

        for rangeToRemove in rangeRemovalOrder {
            removeTokens(in: rangeToRemove)
        }
    }

    /// Moves the tokens in the given range to the new index.
    /// Handles additional internal bookkeeping so this change produces
    /// `Formatter.Change`s that represent moves and won't be filtered out
    /// as redundant.
    func moveTokens(in range: ClosedRange<Int>, to newIndex: Int) {
        let tokensToMove = tokens[range]
        var newIndex = newIndex

        for index in range.reversed() {
            removeToken(at: index, isMove: true)

            if index < newIndex {
                newIndex -= 1
            }
        }

        insert(ArraySlice(tokensToMove), at: newIndex, isMove: true)
    }

    /// Moves the tokens in the given range to the new index.
    /// Handles additional internal bookkeeping so this change produces
    /// `Formatter.Change`s that represent moves and won't be filtered out
    /// as redundant.
    func moveTokens(in range: Range<Int>, to index: Int) {
        moveTokens(in: ClosedRange(range), to: index)
    }

    /// Moves the tokens in the given range to the new index.
    /// Handles additional internal bookkeeping so this change produces
    /// `Formatter.Change`s that represent moves and won't be filtered out
    /// as redundant.
    func moveToken(at originalIndex: Int, to newIndex: Int) {
        moveTokens(in: originalIndex ... originalIndex, to: newIndex)
    }

    /// Removes the last token
    func removeLastToken() {
        trackChange(at: tokens.endIndex - 1)
        updateRange(at: tokens.endIndex - 1, delta: -1)
        tokens.removeLast()
    }

    /// Inserts an array of tokens at the specified index
    func insert(_ tokens: ArraySlice<Token>, at index: Int) {
        insert(tokens, at: index, isMove: false)
    }

    private func insert(_ tokens: ArraySlice<Token>, at index: Int, isMove: Bool) {
        if tokens.isEmpty { return }
        trackChange(at: index, isMove: isMove)
        updateRange(at: index, delta: tokens.count)
        self.tokens.insert(contentsOf: tokens, at: index)
        if enumerationIndex >= index {
            enumerationIndex += tokens.count
        }
    }

    /// Inserts an array of tokens at the specified index
    func insert(_ tokens: [Token], at index: Int) {
        insert(ArraySlice(tokens), at: index)
    }

    /// Inserts a single token at the specified index
    func insert(_ token: Token, at index: Int) {
        trackChange(at: index)
        updateRange(at: index, delta: 1)
        tokens.insert(token, at: index)
        if enumerationIndex >= index {
            enumerationIndex += 1
        }
    }

    // MARK: enumeration

    internal func forEachToken(onlyWhereEnabled: Bool, _ body: (Int, Token) -> Void) {
        assert(enumerationIndex == -1, "forEachToken does not support re-entrancy")
        enumerationIndex = 0
        while enumerationIndex < tokens.count {
            let token = tokens[enumerationIndex]
            switch token {
            case let .commentBody(comment):
                processCommentBody(comment, at: enumerationIndex)
            case .linebreak:
                processLinebreak()
            default:
                break
            }
            if isEnabled || !onlyWhereEnabled {
                body(enumerationIndex, token) // May mutate enumerationIndex
            }
            enumerationIndex += 1
        }
        enumerationIndex = -1
    }

    /// Loops through each token in the array. It is safe to mutate the token
    /// array inside the body block, but note that the index and token arguments
    /// may not reflect the current token any more after a mutation
    func forEachToken(_ body: (Int, Token) -> Void) {
        forEachToken(onlyWhereEnabled: true, body)
    }

    /// As above, but only loops through tokens that match the specified filter block
    func forEachToken(where matching: (Token) -> Bool, _ body: (Int, Token) -> Void) {
        forEachToken { index, token in
            if matching(token) {
                body(index, token)
            }
        }
    }

    /// As above, but only loops through tokens with the specified type and string
    func forEach(_ token: Token, _ body: (Int, Token) -> Void) {
        forEachToken(where: { $0 == token }, body)
    }

    /// As above, but only loops through tokens with the specified type and string
    func forEach(_ type: TokenType, _ body: (Int, Token) -> Void) {
        forEachToken(where: { $0.is(type) }, body)
    }

    // MARK: utilities

    /// Returns the index of the next token in the specified range that matches the block
    func index(in range: CountableRange<Int>, where matches: (Token) -> Bool) -> Int? {
        let range = range.clamped(to: 0 ..< tokens.count)
        var scopeStack: [Token] = []
        for i in range {
            let token = tokens[i]
            // TODO: find a better way to deal with this special case
            if token == .endOfScope("#endif") {
                while let scope = scopeStack.last, scope != .startOfScope("#if") {
                    scopeStack.removeLast()
                }
            }
            if let scope = scopeStack.last, token.isEndOfScope(scope) {
                scopeStack.removeLast()
                if case .linebreak = token, scopeStack.isEmpty, matches(token) {
                    return i
                }
            } else if token.isSwitchCaseOrDefault, scopeStack.last == .startOfScope("#if") {
                continue
            } else if scopeStack.isEmpty, matches(token) {
                return i
            } else if token.isEndOfScope {
                return nil
            } else if case .startOfScope = token {
                scopeStack.append(token)
            }
        }
        return nil
    }

    /// Returns the index of the next token at the current scope that matches the block
    func index(after index: Int, where matches: (Token) -> Bool) -> Int? {
        guard index < tokens.count else { return nil }
        return self.index(in: index + 1 ..< tokens.count, where: matches)
    }

    /// Returns the index of the next matching token in the specified range
    func index(of token: Token, in range: CountableRange<Int>) -> Int? {
        index(in: range, where: { $0 == token })
    }

    /// Returns the index of the next matching token at the current scope
    func index(of token: Token, after index: Int) -> Int? {
        self.index(after: index, where: { $0 == token })
    }

    /// Returns the index of the next token in the specified range of the specified type
    func index(of type: TokenType, in range: CountableRange<Int>, if matches: (Token) -> Bool = { _ in true }) -> Int? {
        index(in: range, where: { $0.is(type) }).flatMap { matches(tokens[$0]) ? $0 : nil }
    }

    /// Returns the index of the next token at the current scope of the specified type
    func index(of type: TokenType, after index: Int, if matches: (Token) -> Bool = { _ in true }) -> Int? {
        self.index(after: index, where: { $0.is(type) }).flatMap { matches(tokens[$0]) ? $0 : nil }
    }

    /// Returns the next token at the current scope that matches the block
    func nextToken(after index: Int, where matches: (Token) -> Bool = { _ in true }) -> Token? {
        self.index(after: index, where: matches).map { tokens[$0] }
    }

    /// Returns the next token at the current scope of the specified type
    func next(_ type: TokenType, after index: Int, if matches: (Token) -> Bool = { _ in true }) -> Token? {
        self.index(of: type, after: index, if: matches).map { tokens[$0] }
    }

    /// Returns the next token in the specified range of the specified type
    func next(_ type: TokenType, in range: CountableRange<Int>, if matches: (Token) -> Bool = { _ in true }) -> Token? {
        index(of: type, in: range, if: matches).map { tokens[$0] }
    }

    /// Returns the index of the last token in the specified range that matches the block
    func lastIndex(in range: CountableRange<Int>, where matches: (Token) -> Bool) -> Int? {
        let range = range.clamped(to: 0 ..< tokens.count)
        var linebreakEncountered = false
        var scopeStack: [Token] = []
        for i in range.reversed() {
            let token = tokens[i]
            if case .startOfScope = token {
                if let scope = scopeStack.last, scope.isEndOfScope(token) {
                    scopeStack.removeLast()
                } else if token.string == "//", linebreakEncountered {
                    linebreakEncountered = false
                } else if matches(token) {
                    return i
                } else if token.string == "//", self.token(at: range.upperBound)?.isLinebreak == true {
                    continue
                } else {
                    return nil
                }
            } else if scopeStack.isEmpty, matches(token) {
                return i
            } else if case .linebreak = token {
                linebreakEncountered = true
            } else if case .endOfScope = token {
                scopeStack.append(token)
            }
        }
        return nil
    }

    /// Returns the index of the previous token at the current scope that matches the block
    func index(before index: Int, where matches: (Token) -> Bool) -> Int? {
        guard index > 0 else { return nil }
        return lastIndex(in: 0 ..< index, where: matches)
    }

    /// Returns the index of the last matching token in the specified range
    func lastIndex(of token: Token, in range: CountableRange<Int>) -> Int? {
        lastIndex(in: range, where: { $0 == token })
    }

    /// Returns the index of the previous matching token at the current scope
    func index(of token: Token, before index: Int) -> Int? {
        self.index(before: index, where: { $0 == token })
    }

    /// Returns the index of the last token in the specified range of the specified type
    func lastIndex(of type: TokenType, in range: CountableRange<Int>, if matches: (Token) -> Bool = { _ in true }) -> Int? {
        lastIndex(in: range, where: { $0.is(type) }).flatMap { matches(tokens[$0]) ? $0 : nil }
    }

    /// Returns the index of the previous token at the current scope of the specified type
    func index(of type: TokenType, before index: Int, if matches: (Token) -> Bool = { _ in true }) -> Int? {
        self.index(before: index, where: { $0.is(type) }).flatMap { matches(tokens[$0]) ? $0 : nil }
    }

    /// Returns the previous token at the current scope that matches the block
    func lastToken(before index: Int, where matches: (Token) -> Bool) -> Token? {
        self.index(before: index, where: matches).map { tokens[$0] }
    }

    /// Returns the previous token at the current scope of the specified type
    func last(_ type: TokenType, before index: Int, if matches: (Token) -> Bool = { _ in true }) -> Token? {
        self.index(of: type, before: index, if: matches).map { tokens[$0] }
    }

    /// Returns the previous token in the specified range of the specified type
    func last(_ type: TokenType, in range: CountableRange<Int>, if matches: (Token) -> Bool = { _ in true }) -> Token? {
        lastIndex(of: type, in: range, if: matches).map { tokens[$0] }
    }

    /// Inserts a linebreak at the specified index
    func insertLinebreak(at index: Int) {
        insert(linebreakToken(for: index), at: index)
    }

    /// Either modifies or removes the existing space token at the specified
    /// index, or inserts a new one if there is not already a space token present.
    /// Returns the number of tokens inserted or removed
    @discardableResult
    func insertSpace(_ space: String, at index: Int) -> Int {
        if token(at: index)?.isSpace == true {
            if space.isEmpty {
                removeToken(at: index)
                return -1 // Removed 1 token
            }
            replaceToken(at: index, with: .space(space))
        } else if !space.isEmpty {
            insert(.space(space), at: index)
            return 1 // Inserted 1 token
        }
        return 0 // Inserted 0 tokens
    }

    /// As above, but only if formatting is enabled
    @discardableResult
    internal func insertSpaceIfEnabled(_ space: String, at index: Int) -> Int {
        isEnabled ? insertSpace(space, at: index) : 0
    }

    /// Returns the original line number at the specified index
    func originalLine(at index: Int) -> OriginalLine {
        for token in tokens[0 ..< index].reversed() {
            if case let .linebreak(_, line) = token {
                return line + 1
            }
        }
        return 1
    }

    /// Indents before the token with the appropriate amount of indentation. Returns difference in tokens.
    @discardableResult
    func wrapLine(before tokenIndex: Int) -> Int {
        var result = 0
        result += insertSpace(currentIndentForLine(at: tokenIndex), at: tokenIndex)
        insertLinebreak(at: tokenIndex)
        result += 1

        // Remove any trailing whitespace that is now orphaned on the previous line
        if tokens[tokenIndex - 1].is(.space) {
            removeToken(at: tokenIndex - 1)
            result -= 1
        }
        return result
    }

    /// Removes linebreaks and space before the token, but not if a line comment is encountered. Returns difference in tokens..
    @discardableResult
    func unwrapLine(before tokenIndex: Int, preservingComments: Bool) -> Int {
        // search backward and replace whitespace with a single " "
        // if we find a line comment (// ...) do not make this change
        let tokenType = preservingComments ? TokenType.nonSpaceOrLinebreak : TokenType.nonSpaceOrCommentOrLinebreak
        guard let notWhitespace = index(of: tokenType, before: tokenIndex) else { return 0 }

        if preservingComments, tokens[notWhitespace].isCommentBody { return 0 }

        let rangeToReplace = (notWhitespace + 1) ..< tokenIndex
        return replaceTokens(in: rangeToReplace, with: [.space(" ")])
    }

    /// Returns a linebreak token suitable for insertion at the specified index
    func linebreakToken(for index: Int) -> Token {
        let lineNumber: Int
        if case let .linebreak(_, index)? = token(at: index) {
            lineNumber = index
        } else {
            lineNumber = originalLine(at: index)
        }
        return .linebreak(options.linebreak, lineNumber)
    }

    /// Formatting linebreaks
    /// Setting `linebreaksCount` linebreaks in `indexes`
    func leaveOrSetLinebreaksInIndexes(_ indexes: Set<Int>, linebreaksCount: Int) {
        var alreadyHasLinebreaksCount = 0
        for index in indexes {
            guard let token = token(at: index) else {
                return
            }
            if token.isLinebreak {
                if alreadyHasLinebreaksCount == linebreaksCount {
                    removeToken(at: index)
                } else {
                    alreadyHasLinebreaksCount += 1
                }
            }
        }
        if alreadyHasLinebreaksCount != linebreaksCount,
           let firstIndex = indexes.first
        {
            insertLinebreak(at: firstIndex)
        }
    }

    /// Registers the given reference to receive range updates as tokens are modified
    /// in this formatter. The registration is automatically cleared after the reference
    /// is deallocated.
    internal func registerAutoUpdatingReference(_ reference: AutoUpdatingReference) {
        autoUpdatingReferences.append(WeakAutoUpdatingReference(reference: reference))
    }

    /// Unregisters the given reference so it will no longer be notified of modifications.
    internal func unregisterAutoUpdatingReference(_ reference: AutoUpdatingReference) {
        autoUpdatingReferences.removeAll(where: { $0.reference === reference })
    }
}

extension String {
    /// https://stackoverflow.com/a/32306142
    func ranges<S: StringProtocol>(of string: S, options: String.CompareOptions = []) -> [Range<Index>] {
        var result: [Range<Index>] = []
        var startIndex = self.startIndex
        while startIndex < endIndex, let range = self[startIndex...].range(of: string, options: options) {
            result.append(range)
            startIndex = range.lowerBound < range.upperBound ? range.upperBound :
                index(range.lowerBound, offsetBy: 1, limitedBy: endIndex) ?? endIndex
        }
        return result
    }
}

private extension Collection where Element == Token, Index == Int {
    /// Ranges of lines within this array of tokens
    var lineRanges: [ClosedRange<Int>] {
        var lineRanges: [ClosedRange<Int>] = []
        var currentLine: ClosedRange<Int>?

        for (index, token) in zip(indices, self) {
            if currentLine == nil {
                currentLine = index ... index
            } else {
                currentLine = currentLine!.lowerBound ... index
            }

            if token.isLinebreak {
                lineRanges.append(currentLine!)
                currentLine = nil
            }
        }

        if let currentLine = currentLine {
            lineRanges.append(currentLine)
        }

        return lineRanges
    }

    /// All of the lines within this array of tokens
    var lines: [SubSequence] {
        lineRanges.map { lineRange in
            self[lineRange]
        }
    }
}

/// A type that references an auto-updating subrange of indicies in a `Formatter`
protocol AutoUpdatingReference: AnyObject {
    var range: ClosedRange<Int> { get set }
}

private struct WeakAutoUpdatingReference {
    weak var reference: AutoUpdatingReference?
}

/// An auto-updating index within an associated `Formatter`
final class AutoUpdatingIndex: AutoUpdatingReference, CustomStringConvertible {
    var index: Int
    let formatter: Formatter

    var range: ClosedRange<Int> {
        get { index ... index }
        set { index = newValue.lowerBound }
    }

    var description: String {
        index.description
    }

    init(index: Int, formatter: Formatter) {
        self.index = index
        self.formatter = formatter
        formatter.registerAutoUpdatingReference(self)
    }

    deinit {
        formatter.unregisterAutoUpdatingReference(self)
    }
}

// An auto-updating subrange of indicies in a `Formatter`
final class AutoUpdatingRange: AutoUpdatingReference, CustomStringConvertible {
    var range: ClosedRange<Int>
    let formatter: Formatter

    var lowerBound: Int {
        range.lowerBound
    }

    var upperBound: Int {
        range.upperBound
    }

    var description: String {
        range.description
    }

    init(range: ClosedRange<Int>, formatter: Formatter) {
        self.range = range
        self.formatter = formatter
        formatter.registerAutoUpdatingReference(self)
    }

    deinit {
        formatter.unregisterAutoUpdatingReference(self)
    }
}

extension Array where Element == WeakAutoUpdatingReference {
    /// Updates the `range` value of the index references in this array
    /// to account for the given addition or removal of tokens.
    mutating func updateRanges(at modifiedIndex: Int, delta: Int) {
        for (tokenIndex, reference) in zip(indices, self).reversed() {
            guard let reference = reference.reference else {
                // If we encounter a reference that no longer exists
                // (the weak reference is nil), clean up the entry.
                remove(at: tokenIndex)
                continue
            }

            var startIndex = reference.range.lowerBound
            var endIndex = reference.range.upperBound

            if modifiedIndex < startIndex {
                startIndex += delta
                endIndex += delta
            } else if modifiedIndex <= endIndex {
                endIndex += delta
            } else {
                // The modification comes after this declaration
                // so doesn't invalidate the indices.
            }

            // Defend against a potential crash here if `endIndex` is less than `startIndex`.
            guard startIndex <= endIndex else {
                reference.range = startIndex ... startIndex
                continue
            }

            reference.range = startIndex ... endIndex
        }
    }
}

extension Int {
    /// Creates a dynamic auto-updating index value from this existing index value,
    /// tracking token changes in the given formatter.
    func autoUpdating(in formatter: Formatter) -> AutoUpdatingIndex {
        AutoUpdatingIndex(index: self, formatter: formatter)
    }
}

extension ClosedRange<Int> {
    /// Creates a dynamic auto-updating range value from this existing range value,
    /// tracking token changes in the given formatter.
    func autoUpdating(in formatter: Formatter) -> AutoUpdatingRange {
        AutoUpdatingRange(range: self, formatter: formatter)
    }
}
