//
//  SpaceInsideBrackets.swift
//  SwiftFormat
//
//  Created by Nick Lockwood on 8/22/16.
//  Copyright © 2024 Nick Lockwood. All rights reserved.
//

import Foundation

public extension FormatRule {
    /// Remove space immediately inside square brackets
    static let spaceInsideBrackets = FormatRule(
        help: "Remove space inside square brackets."
    ) { formatter in
        formatter.forEach(.startOfScope("[")) { i, _ in
            if formatter.token(at: i + 1)?.isSpace == true,
               formatter.token(at: i + 2)?.isComment == false
            {
                formatter.removeToken(at: i + 1)
            }
        }
        formatter.forEach(.endOfScope("]")) { i, _ in
            if formatter.token(at: i - 1)?.isSpace == true,
               formatter.token(at: i - 2)?.isCommentOrLinebreak == false
            {
                formatter.removeToken(at: i - 1)
            }
        }
    } examples: {
        """
        ```diff
        - [ 1, 2, 3 ]
        + [1, 2, 3]
        ```
        """
    }
}
