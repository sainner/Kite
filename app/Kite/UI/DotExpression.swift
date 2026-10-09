import Foundation

/// 点阵签名的表达式：一行算式，每帧按格求值，结果截到 −1 到 1。语法与 kited 的 emblem-expression.ts 一致，改动须两边同步。
/// 解析时编译成闭包，逐格求值不再走语法树。
nonisolated struct DotExpression: Sendable {
    /// 求值时能读到的量，顺序即 Scope 里的下标。
    enum Variable: Int, CaseIterable, Sendable {
        case t, x, y, i, w, h, r, a, px, py, d, k
    }

    /// 一格的变量值，按 Variable 的顺序。
    struct Scope {
        var values = [Double](repeating: 0, count: Variable.allCases.count)
        subscript(_ variable: Variable) -> Double {
            get { values[variable.rawValue] }
            set { values[variable.rawValue] = newValue }
        }
    }

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    typealias Program = @Sendable (UnsafeBufferPointer<Double>) -> Double

    static let maxLength = 240
    private static let maxNodes = 160

    let source: String
    private let program: Program

    init(_ source: String) throws {
        guard source.count <= Self.maxLength else { throw ParseError(message: "表达式不能超过 \(Self.maxLength) 个字符") }
        var parser = Parser(tokens: try Self.tokenize(source))
        guard !parser.tokens.isEmpty else { throw ParseError(message: "表达式为空") }
        program = try parser.parse()
        self.source = source
    }

    /// 非有限数按 0。
    func evaluate(_ scope: Scope) -> Double {
        let value = scope.values.withUnsafeBufferPointer(program)
        return value.isFinite ? min(max(value, -1), 1) : 0
    }

    // MARK: 词法

    private static func tokenize(_ source: String) throws -> [String] {
        let characters = Array(source)
        var tokens: [String] = []
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace { index += 1; continue }
            if c.isASCII && (c.isNumber || (c == "." && index + 1 < characters.count && characters[index + 1].isNumber)) {
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isNumber || characters[end] == "." { end += 1 }
                // 指数部分
                if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                    var probe = end + 1
                    if probe < characters.count, characters[probe] == "+" || characters[probe] == "-" { probe += 1 }
                    if probe < characters.count, characters[probe].isASCII, characters[probe].isNumber {
                        end = probe
                        while end < characters.count, characters[end].isASCII, characters[end].isNumber { end += 1 }
                    }
                }
                tokens.append(String(characters[index..<end]))
                index = end
                continue
            }
            if c.isASCII && (c.isLetter || c == "_") {
                var end = index
                while end < characters.count, characters[end].isASCII, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                tokens.append(String(characters[index..<end]).lowercased())
                index = end
                continue
            }
            if index + 1 < characters.count {
                let pair = String(characters[index...index + 1])
                if ["<=", ">=", "==", "!=", "&&", "||"].contains(pair) { tokens.append(pair); index += 2; continue }
            }
            guard "-+*/%^()<>!?:,".contains(c) else { throw ParseError(message: "第 \(index + 1) 个字符无法识别") }
            tokens.append(String(c))
            index += 1
        }
        return tokens
    }

    // MARK: 语法

    private struct Parser {
        let tokens: [String]
        var index = 0
        var nodes = 0

        mutating func parse() throws -> Program {
            let result = try expression()
            if index < tokens.count { throw ParseError(message: "多余的「\(tokens[index])」") }
            return result
        }

        private var peek: String? { index < tokens.count ? tokens[index] : nil }

        @discardableResult
        private mutating func take(_ expected: String? = nil) throws -> String {
            guard let token = peek else { throw ParseError(message: "表达式不完整") }
            if let expected, token != expected { throw ParseError(message: "应为「\(expected)」，实际是「\(token)」") }
            index += 1
            return token
        }

        private mutating func count() throws {
            nodes += 1
            if nodes > DotExpression.maxNodes { throw ParseError(message: "表达式过于复杂") }
        }

        private mutating func expression() throws -> Program {
            let test = try or()
            guard peek == "?" else { return test }
            try take()
            let yes = try expression()
            try take(":")
            let no = try expression()
            try count()
            return { test($0) != 0 ? yes($0) : no($0) }
        }

        private mutating func or() throws -> Program {
            try binary(next: { try $0.and() }, ops: ["||"])
        }
        private mutating func and() throws -> Program {
            try binary(next: { try $0.comparison() }, ops: ["&&"])
        }
        private mutating func comparison() throws -> Program {
            try binary(next: { try $0.sum() }, ops: ["<", ">", "<=", ">=", "==", "!="])
        }
        private mutating func sum() throws -> Program {
            try binary(next: { try $0.product() }, ops: ["+", "-"])
        }
        private mutating func product() throws -> Program {
            try binary(next: { try $0.unary() }, ops: ["*", "/", "%"])
        }

        private mutating func binary(next: (inout Parser) throws -> Program, ops: Set<String>) throws -> Program {
            var left = try next(&self)
            while let token = peek, ops.contains(token) {
                try take()
                let right = try next(&self)
                try count()
                left = Self.combine(token, left, right)
            }
            return left
        }

        private static func combine(_ op: String, _ l: @escaping Program, _ r: @escaping Program) -> Program {
            switch op {
            case "+": { l($0) + r($0) }
            case "-": { l($0) - r($0) }
            case "*": { l($0) * r($0) }
            case "/": { l($0) / r($0) }
            case "%": { let a = l($0), b = r($0); return a - b * (a / b).rounded(.down) }
            case "^": { pow(l($0), r($0)) }
            case "<": { l($0) < r($0) ? 1 : 0 }
            case ">": { l($0) > r($0) ? 1 : 0 }
            case "<=": { l($0) <= r($0) ? 1 : 0 }
            case ">=": { l($0) >= r($0) ? 1 : 0 }
            case "==": { l($0) == r($0) ? 1 : 0 }
            case "!=": { l($0) != r($0) ? 1 : 0 }
            case "&&": { l($0) != 0 && r($0) != 0 ? 1 : 0 }
            default: { l($0) != 0 || r($0) != 0 ? 1 : 0 }
            }
        }

        private mutating func unary() throws -> Program {
            if let token = peek, ["-", "+", "!"].contains(token) {
                try take()
                let operand = try unary()
                try count()
                switch token {
                case "-": return { -operand($0) }
                case "!": return { operand($0) == 0 ? 1 : 0 }
                default: return operand
                }
            }
            return try power()
        }

        private mutating func power() throws -> Program {
            let base = try primary()
            guard peek == "^" else { return base }
            try take()
            let exponent = try unary()
            try count()
            return { pow(base($0), exponent($0)) }
        }

        private mutating func primary() throws -> Program {
            let token = try take()
            if token == "(" {
                let value = try expression()
                try take(")")
                return value
            }
            try count()
            if let first = token.first, first.isNumber || first == "." {
                guard let value = Double(token) else { throw ParseError(message: "数字「\(token)」无效") }
                return { _ in value }
            }
            if peek == "(" {
                try take("(")
                var args: [Program] = []
                if peek != ")" {
                    args.append(try expression())
                    while peek == "," {
                        try take()
                        args.append(try expression())
                    }
                }
                try take(")")
                return try Self.call(token, args)
            }
            switch token {
            case "pi": return { _ in .pi }
            case "tau": return { _ in 2 * .pi }
            default:
                guard let variable = Variable.allCases.first(where: { "\($0)" == token }) else {
                    throw ParseError(message: "不支持变量 \(token)")
                }
                let slot = variable.rawValue
                return { $0[slot] }
            }
        }

        private static let arities: [String: [Int]] = [
            "sin": [1], "cos": [1], "tan": [1], "abs": [1], "floor": [1], "ceil": [1], "round": [1], "sqrt": [1], "exp": [1],
            "log": [1], "sign": [1], "fract": [1], "min": [2], "max": [2], "pow": [2], "hypot": [2], "atan2": [2], "mod": [2],
            "clamp": [3], "mix": [3], "noise": [2, 3],
        ]

        private static func call(_ name: String, _ args: [Program]) throws -> Program {
            guard let allowed = arities[name] else { throw ParseError(message: "不支持函数 \(name)") }
            guard allowed.contains(args.count) else { throw ParseError(message: "函数 \(name) 的参数个数不对") }
            let a = args[0]
            let zero: Program = { _ in 0 }
            let b = args.count > 1 ? args[1] : zero
            let c = args.count > 2 ? args[2] : zero
            switch name {
            case "sin": return { sin(a($0)) }
            case "cos": return { cos(a($0)) }
            case "tan": return { tan(a($0)) }
            case "abs": return { abs(a($0)) }
            case "floor": return { a($0).rounded(.down) }
            case "ceil": return { a($0).rounded(.up) }
            // 与 JavaScript 的 Math.round 一致：.5 向正无穷取整
            case "round": return { (a($0) + 0.5).rounded(.down) }
            case "sqrt": return { sqrt(a($0)) }
            case "exp": return { exp(a($0)) }
            case "log": return { log(a($0)) }
            case "sign": return { let v = a($0); return v > 0 ? 1 : v < 0 ? -1 : 0 }
            case "fract": return { let v = a($0); return v - v.rounded(.down) }
            case "min": return { Swift.min(a($0), b($0)) }
            case "max": return { Swift.max(a($0), b($0)) }
            case "pow": return { pow(a($0), b($0)) }
            case "hypot": return { hypot(a($0), b($0)) }
            case "atan2": return { atan2(a($0), b($0)) }
            case "mod": return { let x = a($0), y = b($0); return x - y * (x / y).rounded(.down) }
            case "clamp": return { Swift.min(Swift.max(a($0), b($0)), c($0)) }
            case "mix": return { let x = a($0); return x + (b($0) - x) * c($0) }
            default: return { DotExpression.noise(a($0), b($0), c($0)) }
            }
        }
    }

    /// 三维值噪声，输出 −1 到 1，与 kited 的 emblemNoise 相同。
    static func noise(_ x: Double, _ y: Double, _ z: Double) -> Double {
        func fract(_ v: Double) -> Double { v - v.rounded(.down) }
        func hash(_ x: Double, _ y: Double, _ z: Double) -> Double { fract(sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453) }
        func smooth(_ v: Double) -> Double { v * v * (3 - 2 * v) }
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let ix = x.rounded(.down), iy = y.rounded(.down), iz = z.rounded(.down)
        let fx = smooth(x - ix), fy = smooth(y - iy), fz = smooth(z - iz)
        func layer(_ zz: Double) -> Double {
            lerp(lerp(hash(ix, iy, zz), hash(ix + 1, iy, zz), fx), lerp(hash(ix, iy + 1, zz), hash(ix + 1, iy + 1, zz), fx), fy)
        }
        return lerp(layer(iz), layer(iz + 1), fz) * 2 - 1
    }
}
